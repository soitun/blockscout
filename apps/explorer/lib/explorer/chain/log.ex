defmodule Explorer.Chain.Log.Schema do
  @moduledoc false
  use Utils.CompileTimeEnvHelper, chain_type: [:explorer, :chain_type]

  alias Explorer.Chain.{
    Address,
    Block,
    Data,
    Hash,
    Transaction
  }

  # In certain situations, like on Polygon, multiple logs may share the same
  # index within a single block due to a RPC node bug. To prevent system crashes
  # due to not unique primary keys, we've included `transaction_hash` in the
  # primary key.
  #
  # However, on Celo, logs may exist where `transaction_hash` equals block_hash.
  # In these instances, we set `transaction_hash` to `nil`. This action, though,
  # violates the primary key constraint. To resolve this issue, we've excluded
  # `transaction_hash` from the composite primary key when dealing with `:celo`
  # chain type.
  @transaction_field (case @chain_type do
                        :celo ->
                          quote do
                            [
                              belongs_to(:transaction, Transaction,
                                foreign_key: :transaction_hash,
                                references: :hash,
                                type: Hash.Full
                              )
                            ]
                          end

                        _ ->
                          quote do
                            [
                              belongs_to(:transaction, Transaction,
                                foreign_key: :transaction_hash,
                                primary_key: true,
                                references: :hash,
                                type: Hash.Full,
                                null: false
                              )
                            ]
                          end
                      end)

  defmacro generate do
    quote do
      @primary_key false
      typed_schema "logs" do
        field(:data, Data, null: false)
        field(:first_topic, Hash.Full)
        field(:second_topic, Hash.Full)
        field(:third_topic, Hash.Full)
        field(:fourth_topic, Hash.Full)
        field(:index, :integer, primary_key: true, null: false)
        field(:block_number, :integer)

        timestamps()

        belongs_to(:address, Address, foreign_key: :address_hash, references: :hash, type: Hash.Address, null: false)

        belongs_to(:block, Block,
          foreign_key: :block_hash,
          primary_key: true,
          references: :hash,
          type: Hash.Full,
          null: false
        )

        unquote_splicing(@transaction_field)
      end
    end
  end
end

defmodule Explorer.Chain.Log do
  @moduledoc "Captures a Web3 log entry generated by a transaction"

  use Explorer.Schema
  use Utils.CompileTimeEnvHelper, chain_type: [:explorer, :chain_type]

  require Explorer.Chain.Log.Schema
  require Logger

  alias ABI.{Event, FunctionSelector}
  alias Explorer.{Chain, Repo}
  alias Explorer.Chain.{ContractMethod, Hash, Log, TokenTransfer, Transaction}
  alias Explorer.SmartContract.SigProviderInterface

  @required_attrs ~w(address_hash data block_hash index)a
                  |> (&(case @chain_type do
                          :celo ->
                            &1

                          _ ->
                            [:transaction_hash | &1]
                        end)).()

  @optional_attrs ~w(first_topic second_topic third_topic fourth_topic block_number)a
                  |> (&(case @chain_type do
                          :celo ->
                            [:transaction_hash | &1]

                          _ ->
                            &1
                        end)).()

  @typedoc """
   * `address` - address of contract that generate the event
   * `block_hash` - hash of the block
   * `block_number` - The block number that the transfer took place.
   * `address_hash` - foreign key for `address`
   * `data` - non-indexed log parameters.
   * `first_topic` - `topics[0]`
   * `second_topic` - `topics[1]`
   * `third_topic` - `topics[2]`
   * `fourth_topic` - `topics[3]`
   * `transaction` - transaction for which `log` is
   * `transaction_hash` - foreign key for `transaction`.
   * `index` - index of the log entry within the block
  """
  Explorer.Chain.Log.Schema.generate()

  @doc """
  `address_hash` and `transaction_hash` are converted to `t:Explorer.Chain.Hash.t/0`.

      iex> changeset = Explorer.Chain.Log.changeset(
      ...>   %Explorer.Chain.Log{},
      ...>   %{
      ...>     address_hash: "0x8bf38d4764929064f2d4d3a56520a76ab3df415b",
      ...>     block_hash: "0xf6b4b8c88df3ebd252ec476328334dc026cf66606a84fb769b3d3cbccc8471bd",
      ...>     data: "0x000000000000000000000000862d67cb0773ee3f8ce7ea89b328ffea861ab3ef",
      ...>     first_topic: "0x600bcf04a13e752d1e3670a5a9f1c21177ca2a93c6f5391d4f1298d098097c22",
      ...>     fourth_topic: nil,
      ...>     index: 0,
      ...>     second_topic: nil,
      ...>     third_topic: nil,
      ...>     transaction_hash: "0x53bd884872de3e488692881baeec262e7b95234d3965248c39fe992fffd433e5"
      ...>   }
      ...> )
      iex> changeset.valid?
      true
      iex> changeset.changes.address_hash
      %Explorer.Chain.Hash{
        byte_count: 20,
        bytes: <<139, 243, 141, 71, 100, 146, 144, 100, 242, 212, 211, 165, 101, 32, 167, 106, 179, 223, 65, 91>>
      }
      iex> changeset.changes.transaction_hash
      %Explorer.Chain.Hash{
        byte_count: 32,
        bytes: <<83, 189, 136, 72, 114, 222, 62, 72, 134, 146, 136, 27, 174, 236, 38, 46, 123, 149, 35, 77, 57, 101, 36,
                 140, 57, 254, 153, 47, 255, 212, 51, 229>>
      }

  """
  def changeset(%__MODULE__{} = log, attrs \\ %{}) do
    log
    |> cast(attrs, @required_attrs)
    |> cast(attrs, @optional_attrs)
    |> validate_required(@required_attrs)
  end

  @doc """
  Decode transaction log data.
  """
  @spec decode(Log.t(), Transaction.t(), any(), boolean(), boolean(), list(), map()) ::
          {{:ok, String.t(), String.t(), map()}
           | {:error, :could_not_decode}
           | {:error, atom(), list()}
           | {{:error, :contract_not_verified | :try_with_sig_provider, [any()]}, any()}, map()}
  def decode(
        log,
        transaction,
        db_options,
        skip_sig_provider?,
        decoding_from_list?,
        full_abi,
        events_acc \\ %{}
      ) do
    with {:no_abi, false} <- {:no_abi, is_nil(full_abi)},
         {:ok, selector, mapping} <- find_and_decode(full_abi, log, transaction.hash),
         identifier <- Base.encode16(selector.method_id, case: :lower),
         text <- function_call(selector.function, mapping) do
      {{:ok, identifier, text, mapping}, events_acc}
    else
      {:error, _} = error ->
        handle_method_decode_error(
          error,
          log,
          transaction,
          skip_sig_provider?,
          decoding_from_list?,
          db_options,
          events_acc
        )

      {:no_abi, true} ->
        handle_method_decode_error(
          {:error, :could_not_decode},
          log,
          transaction,
          skip_sig_provider?,
          decoding_from_list?,
          db_options,
          events_acc
        )
    end
  end

  defp handle_method_decode_error(
         error,
         log,
         transaction,
         skip_sig_provider?,
         decoding_from_list?,
         db_options,
         events_acc
       ) do
    case error do
      {:error, _reason} ->
        with {{:error, :contract_not_verified, candidates}, events_acc} <-
               find_method_candidates(log, transaction, db_options, events_acc),
             {true, events_acc} <- {is_list(candidates), events_acc},
             {false, events_acc} <- {Enum.empty?(candidates), events_acc} do
          {{:error, :contract_not_verified, candidates}, events_acc}
        else
          {_, events_acc} ->
            result =
              if decoding_from_list? do
                mark_events_to_decode_later_via_sig_provider_in_batch(log, transaction.hash)
              else
                decode_event_via_sig_provider(log, transaction.hash, skip_sig_provider?)
              end

            {result, events_acc}
        end
    end
  end

  defp find_method_candidates(log, transaction, options, events_acc) do
    if is_nil(log.first_topic) do
      {{:error, :could_not_decode}, events_acc}
    else
      <<method_id::binary-size(4), _rest::binary>> = log.first_topic.bytes

      if Map.has_key?(events_acc, method_id) do
        {find_and_decode_in_candidates(events_acc[method_id], log, transaction), events_acc}
      else
        {result, event_candidates} = find_method_candidates_from_db(method_id, log, transaction, options)
        {result, Map.put(events_acc, method_id, event_candidates)}
      end
    end
  end

  defp find_method_candidates_from_db(method_id, log, transaction, options) do
    event_candidates =
      method_id
      |> ContractMethod.find_contract_method_query(3)
      |> Chain.select_repo(options).all()

    {find_and_decode_in_candidates(event_candidates, log, transaction), event_candidates}
  end

  defp find_and_decode_in_candidates(event_candidates, log, transaction) do
    result =
      event_candidates
      |> Enum.flat_map(fn contract_method ->
        case find_and_decode([contract_method.abi], log, transaction.hash) do
          {:ok, selector, mapping} ->
            identifier = Base.encode16(selector.method_id, case: :lower)
            text = function_call(selector.function, mapping)

            [{:ok, identifier, text, mapping}]

          _ ->
            []
        end
      end)
      |> Enum.take(1)

    {:error, :contract_not_verified, result}
  end

  @spec find_and_decode([map()], __MODULE__.t(), Hash.t()) ::
          {:error, any} | {:ok, ABI.FunctionSelector.t(), any}
  def find_and_decode(abi, log, transaction_hash) do
    # For events, the method_id (signature) is 32 bytes, whereas for methods and
    # errors it is 4 bytes. To avoid complications with different sizes, we
    # always take only the first 4 bytes of the hash.
    with {%FunctionSelector{method_id: <<first_four_bytes::binary-size(4), _::binary>>} = selector, mapping} <-
           abi
           |> ABI.parse_specification(include_events?: true)
           |> Event.find_and_decode(
             log.first_topic && log.first_topic.bytes,
             log.second_topic && log.second_topic.bytes,
             log.third_topic && log.third_topic.bytes,
             log.fourth_topic && log.fourth_topic.bytes,
             log.data.bytes
           ),
         selector <- %FunctionSelector{selector | method_id: first_four_bytes} do
      {:ok, alter_inputs_names(selector), alter_mapping_names(mapping)}
    end
  rescue
    e ->
      Logger.warning(fn ->
        [
          "Could not decode input data for log from transaction hash: ",
          Hash.to_iodata(transaction_hash),
          Exception.format(:error, e, __STACKTRACE__)
        ]
      end)

      {:error, :could_not_decode}
  end

  defp function_call(name, mapping) do
    text =
      mapping
      |> Stream.map(fn {name, type, indexed?, _value} ->
        indexed_keyword = if indexed?, do: ["indexed "], else: []

        [type, " ", indexed_keyword, name]
      end)
      |> Enum.intersperse(", ")

    IO.iodata_to_binary([name, "(", text, ")"])
  end

  defp alter_inputs_names(%FunctionSelector{input_names: names} = selector) do
    names =
      names
      |> Enum.with_index()
      |> Enum.map(fn {name, index} ->
        if name == "", do: "arg#{index}", else: name
      end)

    %FunctionSelector{selector | input_names: names}
  end

  defp alter_mapping_names(mapping) when is_list(mapping) do
    mapping
    |> Enum.with_index()
    |> Enum.map(fn {{name, type, indexed?, value}, index} ->
      name = if name == "", do: "arg#{index}", else: name
      {name, type, indexed?, value}
    end)
  end

  defp alter_mapping_names(mapping), do: mapping

  defp mark_events_to_decode_later_via_sig_provider_in_batch(
         log,
         transaction_hash
       ) do
    {:error, :try_with_sig_provider, {log, transaction_hash}}
  end

  @doc """
  Decodes an event log using the Sig-provider microservice.

  ## Parameters

    - `log`: The log containing the event data and topics.
    - `transaction_hash`: The hash of the transaction containing the log.
    - `skip_sig_provider?`: A boolean indicating whether to skip using the signature provider.

  ## Returns

    - `{:error, :contract_not_verified, [{:ok, identifier, text, mapping}]}` if the event is successfully decoded but the contract is not verified.
    - `{:error, :could_not_decode}` if the event could not be decoded.

  ## Conditions

    - The signature provider must be enabled.
    - The `skip_sig_provider?` flag must be `false`.
    - The result from the signature provider must be a non-empty list.
  """
  @spec decode_event_via_sig_provider(
          __MODULE__.t(),
          Hash.t(),
          boolean()
        ) ::
          {:error, :could_not_decode} | {:error, :contract_not_verified, list()}
  def decode_event_via_sig_provider(
        log,
        transaction_hash,
        skip_sig_provider?
      ) do
    with true <- SigProviderInterface.enabled?(),
         false <- skip_sig_provider?,
         false <- is_nil(log.first_topic),
         {:ok, result} <-
           SigProviderInterface.decode_event(
             [
               log.first_topic,
               log.second_topic,
               log.third_topic,
               log.fourth_topic
             ],
             log.data
           ),
         true <- is_list(result),
         false <- Enum.empty?(result),
         abi <- [result |> List.first() |> Map.put("type", "event")],
         {:ok, selector, mapping} <- find_and_decode(abi, log, transaction_hash),
         identifier <- Base.encode16(selector.method_id, case: :lower),
         text <- function_call(selector.function, mapping) do
      {:error, :contract_not_verified, [{:ok, identifier, text, mapping}]}
    else
      _ ->
        {:error, :could_not_decode}
    end
  end

  @doc """
  Decodes a batch of events using the Sig-provider microservice.

  This function attempts to decode a batch of events by leveraging the signature provider interface.
  It first checks if the signature provider is enabled and if it should not be skipped.
  If these conditions are met, it prepares the input for the signature provider batch request and decodes the events.
  The decoded results are then processed and mapped to their corresponding logs and transaction hashes.

  ## Parameters

    - `input`: The input data to be decoded, expected to be a list of maps containing `:log` and `:transaction_hash`.
    - `skip_sig_provider?`: A boolean flag indicating whether to skip the signature provider.

  ## Returns

    - On success: A list of tuples containing the decoded event information.
    - On failure: `{:error, :could_not_decode}` if the decoding process fails at any step.
  """
  @spec decode_events_batch_via_sig_provider(
          [
            %{
              :log => __MODULE__.t(),
              :transaction_hash => Hash.t()
            }
          ],
          boolean()
        ) ::
          {:error, :contract_not_verified, list()} | list()
  def decode_events_batch_via_sig_provider([], _skip_sig_provider?), do: []

  def decode_events_batch_via_sig_provider(input, skip_sig_provider?) do
    with true <- SigProviderInterface.enabled?(),
         false <- skip_sig_provider?,
         {:ok, result} <-
           SigProviderInterface.decode_events_in_batch(prepare_input_for_sig_provider_batch_request(input)),
         true <- is_list(result),
         false <- Enum.empty?(result) do
      input
      |> Enum.zip(result)
      |> Enum.map(fn {{index,
                       %{
                         :log => log,
                         :transaction_hash => transaction_hash
                       }}, %{"abi" => abi}} ->
        abi_first_item = abi |> List.first()

        if is_map(abi_first_item) do
          abi = [abi_first_item |> Map.put("type", "event")]

          {:ok, selector, mapping} = find_and_decode(abi, log, transaction_hash)

          identifier = Base.encode16(selector.method_id, case: :lower)
          text = function_call(selector.function, mapping)

          {index, {:error, :contract_not_verified, [{:ok, identifier, text, mapping}]}}
        else
          {index, {:error, :could_not_decode}}
        end
      end)
    else
      _ ->
        input
        |> Enum.map(fn {index, _} -> {index, {:error, :could_not_decode}} end)
    end
  end

  defp prepare_input_for_sig_provider_batch_request(input) do
    input
    |> Enum.map(fn {_index, %{:log => log, :transaction_hash => _transaction_hash}} ->
      topics = [
        log.first_topic,
        log.second_topic,
        log.third_topic,
        log.fourth_topic
      ]

      formatted_topics =
        topics |> Enum.reject(&is_nil/1) |> Enum.join(",")

      %{
        :topics => formatted_topics,
        :data => to_string(log.data)
      }
    end)
  end

  def fetch_log_by_transaction_hash_and_first_topic(transaction_hash, first_topic, options \\ []) do
    __MODULE__
    |> where([l], l.transaction_hash == ^transaction_hash and l.first_topic == ^first_topic)
    |> limit(1)
    |> Chain.select_repo(options).one()
  end

  @doc """
  Fetches logs by user operation.
  """
  @spec user_op_to_logs(map(), Keyword.t()) :: [t()]
  def user_op_to_logs(user_op, options) do
    necessity_by_association = Keyword.get(options, :necessity_by_association, %{})
    limit = Keyword.get(options, :limit, 50)

    __MODULE__
    |> where([log], log.block_hash == ^user_op["block_hash"] and log.transaction_hash == ^user_op["transaction_hash"])
    |> where([log], log.index >= ^user_op["user_logs_start_index"])
    |> order_by([log], asc: log.index)
    |> limit(^min(user_op["user_logs_count"], limit))
    |> Chain.join_associations(necessity_by_association)
    |> Chain.select_repo(options).all()
  end

  @doc """
  Streams unfetched WETH token transfers.
  Returns `{:ok, any()} | {:error, any()}` (return spec taken from Ecto.Repo.transaction/2)
  Expects each_fun, a function to be called on each fetched log. It should accept log and return anything (return value will be discarded anyway)
  """
  @spec stream_unfetched_weth_token_transfers((Log.t() -> any())) :: {:ok, any()} | {:error, any()}
  def stream_unfetched_weth_token_transfers(each_fun) do
    env = Application.get_env(:explorer, Explorer.Chain.TokenTransfer)

    base_query = from(log in __MODULE__, as: :log)

    base_query
    |> where([log], log.address_hash in ^env[:whitelisted_weth_contracts])
    |> where(^first_topic_is_deposit_or_withdrawal_signature())
    |> join(:left, [log], tt in TokenTransfer,
      on: log.block_hash == tt.block_hash and log.transaction_hash == tt.transaction_hash and log.index == tt.log_index
    )
    |> where([log, tt], is_nil(tt.transaction_hash))
    |> select([log], log)
    |> Repo.stream_each(each_fun)
  end

  @doc """
  Generates a dynamic query condition to check if the `first_topic` of a log entry
  matches either the WETH deposit or withdrawal signature.

  This function is typically used to filter logs where the first topic corresponds
  to specific token transfer events, such as WETH deposits or withdrawals.

  ## Returns

  - An `Ecto.Query.dynamic()` expression that can be used in Ecto queries.
  """
  @spec first_topic_is_deposit_or_withdrawal_signature() :: Ecto.Query.dynamic_expr()
  def first_topic_is_deposit_or_withdrawal_signature do
    dynamic(
      [log: log],
      log.first_topic in [^TokenTransfer.weth_deposit_signature(), ^TokenTransfer.weth_withdrawal_signature()]
    )
  end

  @doc """
  Generates a dynamic query condition to filter logs where the `first_topic`
  is neither the WETH deposit signature nor the WETH withdrawal signature.

  This function is useful for excluding specific types of token transfer events
  from query results.

  ## Returns

  - An `Ecto.Query.dynamic/1` expression that can be used in Ecto queries.
  """
  @spec first_topic_is_not_deposit_or_withdrawal_signature() :: Ecto.Query.dynamic_expr()
  def first_topic_is_not_deposit_or_withdrawal_signature do
    dynamic(
      [log: log],
      log.first_topic not in [^TokenTransfer.weth_deposit_signature(), ^TokenTransfer.weth_withdrawal_signature()]
    )
  end
end
