defmodule Explorer.Staking.ContractState do
  @moduledoc """
  Fetches all information from POSDAO staking contracts.
  All contract calls are batched into four requests, according to their dependencies.
  Subscribes to new block notifications and refreshes when previously unseen block arrives.
  """

  use GenServer

  require Logger

  alias Explorer.Chain
  alias Explorer.Chain.Events.{Publisher, Subscriber}
  alias Explorer.SmartContract.Reader
  alias Explorer.Staking.{ContractReader, StakeSnapshotting}

  @table_name __MODULE__
  @table_keys [
    :token_contract_address,
    :token,
    :min_candidate_stake,
    :min_delegator_stake,
    :epoch_number,
    :epoch_start_block,
    :epoch_end_block,
    :staking_allowed,
    :staking_contract,
    :validator_set_contract,
    :block_reward_contract,
    :validator_set_apply_block,
    :validator_min_reward_percent,
    :is_snapshotted
  ]

  defstruct [
    :seen_block,
    :contracts,
    :abi
  ]

  @spec get(atom(), value) :: value when value: any()
  def get(key, default \\ nil) when key in @table_keys do
    with info when info != :undefined <- :ets.info(@table_name),
         [{_, value}] <- :ets.lookup(@table_name, key) do
      value
    else
      _ -> default
    end
  end

  def start_link([]) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init([]) do
    :ets.new(@table_name, [
      :set,
      :named_table,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    Subscriber.to(:blocks, :realtime)

    staking_abi = abi("StakingAuRa")
    validator_set_abi = abi("ValidatorSetAuRa")
    block_reward_abi = abi("BlockRewardAuRa")

    staking_contract_address = Application.get_env(:explorer, __MODULE__)[:staking_contract_address]

    %{
      "validatorSetContract" => {:ok, [validator_set_contract_address]},
      "erc677TokenContract" => {:ok, [token_contract_address]}
    } =
      Reader.query_contract(staking_contract_address, staking_abi, %{
        "validatorSetContract" => [],
        "erc677TokenContract" => []
      })

    %{"blockRewardContract" => {:ok, [block_reward_contract_address]}} =
      Reader.query_contract(validator_set_contract_address, validator_set_abi, %{"blockRewardContract" => []})

    state = %__MODULE__{
      seen_block: 0,
      contracts: %{
        staking: staking_contract_address,
        validator_set: validator_set_contract_address,
        block_reward: block_reward_contract_address
      },
      abi: staking_abi ++ validator_set_abi ++ block_reward_abi
    }

    :ets.insert(@table_name,
      staking_contract: %{abi: staking_abi, address: staking_contract_address},
      validator_set_contract: %{abi: validator_set_abi, address: validator_set_contract_address},
      block_reward_contract: %{abi: block_reward_abi, address: block_reward_contract_address},
      token_contract_address: token_contract_address,
      token: get_token(token_contract_address),
      is_snapshotted: false
    )

    {:ok, state, {:continue, []}}
  end

  def handle_continue(_, state) do
    fetch_state(state.contracts, state.abi, state.seen_block)
    {:noreply, state}
  end

  @doc "Handles new blocks and decides to fetch fresh chain info"
  def handle_info({:chain_event, :blocks, :realtime, blocks}, state) do
    latest_block = Enum.max_by(blocks, & &1.number)

    if latest_block.number > state.seen_block do
      fetch_state(state.contracts, state.abi, latest_block.number)
      {:noreply, %{state | seen_block: latest_block.number}}
    else
      {:noreply, state}
    end
  end

  defp fetch_state(contracts, abi, block_number) do
    # read general info from the contracts (including pool list and validator list)
    global_responses = ContractReader.perform_requests(ContractReader.global_requests(), contracts, abi)
    token = get_token(global_responses.token_contract_address)
    validator_min_reward_percent = ContractReader.perform_requests(
      ContractReader.validator_min_reward_percent_request(global_responses.epoch_number), contracts, abi
    ).value

    start_snapshotting = (global_responses.epoch_start_block == block_number + 1)
    is_validator = Enum.into(global_responses.validators, %{}, &{hash_to_string(&1), true})
    unremovable_validator = global_responses.unremovable_validator

    # save the general info to ETS (excluding pool list and validator list)
    settings =
      global_responses
      |> Map.take([
        :token_contract_address,
        :min_candidate_stake,
        :min_delegator_stake,
        :epoch_number,
        :epoch_start_block,
        :epoch_end_block,
        :staking_allowed,
        :validator_set_apply_block
      ])
      |> Map.to_list()
      |> Enum.concat(token: token)
      |> Enum.concat(validator_min_reward_percent: validator_min_reward_percent)

    :ets.insert(@table_name, settings)

    # form the list of all pools
    validators = if start_snapshotting do
      %{
        "getPendingValidators" => {:ok, [pending_validators]},
        "validatorsToBeFinalized" => {:ok, [to_be_finalized_validators]}
      } = Reader.query_contract(contracts.validator_set, abi, %{
        "getPendingValidators" => [],
        "validatorsToBeFinalized" => []
      })
      validators_pending = Enum.uniq(pending_validators ++ to_be_finalized_validators)
      # get the list of all validators (the current and pending)
      %{
        all: Enum.uniq(global_responses.validators ++ validators_pending),
        pending: validators_pending
      }
    else
      %{all: global_responses.validators}
    end

    mining_to_staking_address =
      validators.all
      |> Enum.map(&ContractReader.staking_by_mining_requests/1)
      |> ContractReader.perform_grouped_requests(validators.all, contracts, abi)
      |> Map.new(fn {mining_address, resp} -> {mining_address, ContractReader.decode_data(resp.staking_address)} end)

    pools = Enum.uniq(
      Map.values(mining_to_staking_address) ++
      global_responses.active_pools ++
      global_responses.inactive_pools
    )

    # read info about each pool from the contracts (including delegator list)
    pool_staking_responses =
      pools
      |> Enum.map(&ContractReader.pool_staking_requests/1)
      |> ContractReader.perform_grouped_requests(pools, contracts, abi)

    pool_mining_responses =
      pools
      |> Enum.map(&ContractReader.pool_mining_requests(pool_staking_responses[&1].mining_address_hash))
      |> ContractReader.perform_grouped_requests(pools, contracts, abi)

    # form a flat list of all stakers in the form {pool_staking_address, staker_address, is_active}
    stakers =
      Enum.flat_map(pool_staking_responses, fn {pool_staking_address, resp} ->
        [{pool_staking_address, pool_staking_address, true}] ++
          Enum.map(resp.active_delegators, &{pool_staking_address, &1, true}) ++
          Enum.map(resp.inactive_delegators, &{pool_staking_address, &1, false})
      end)

    # get amounts for each of the stakers
    staker_responses =
      stakers
      |> Enum.map(fn {pool_staking_address, staker_address, _is_active} ->
        ContractReader.staker_requests(pool_staking_address, staker_address)
      end)
      |> ContractReader.perform_grouped_requests(stakers, contracts, abi)

    # to keep sort order
    pool_staking_keys = Enum.map(pool_staking_responses, fn {key, _} -> key end)

    candidate_reward_responses =
      pool_staking_responses
      |> Enum.map(fn {_pool_staking_address, resp} ->
        ContractReader.validator_reward_requests([
          global_responses.epoch_number,
          resp.self_staked_amount,
          resp.total_staked_amount,
          1000_000
        ])
      end)
      |> ContractReader.perform_grouped_requests(pool_staking_keys, contracts, abi)

    # to keep sort order
    delegator_keys = Enum.map(staker_responses, fn {key, _} -> key end)

    delegator_reward_responses =
      staker_responses
      |> Enum.map(fn {{pool_staking_address, _staker_address, _is_active}, resp} ->
        staking_resp = pool_staking_responses[pool_staking_address]

        ContractReader.delegator_reward_requests([
          global_responses.epoch_number,
          resp.stake_amount,
          staking_resp.self_staked_amount,
          staking_resp.total_staked_amount,
          1000_000
        ])
      end)
      |> ContractReader.perform_grouped_requests(delegator_keys, contracts, abi)

    # calculate total amount staked into all active pools
    staked_total = Enum.sum(for {_, pool} <- pool_staking_responses, pool.is_active, do: pool.total_staked_amount)

    # calculate likelihood of becoming a validator on the next epoch
    [likelihood_values, total_likelihood] = global_responses.pools_likelihood

    likelihood =
      global_responses.pools_to_be_elected # array of pool addresses (staking addresses)
      |> Enum.zip(likelihood_values)
      |> Enum.into(%{})

    # form entries for writing to the `staking_pools` table in DB
    pool_entries =
      Enum.map(pools, fn pool_staking_address ->
        staking_resp = pool_staking_responses[pool_staking_address]
        mining_resp = pool_mining_responses[pool_staking_address]
        candidate_reward_resp = candidate_reward_responses[pool_staking_address]

        %{
          staking_address_hash: pool_staking_address,
          delegators_count: length(staking_resp.active_delegators),
          stakes_ratio:
            if staking_resp.is_active do
              ratio(staking_resp.total_staked_amount, staked_total)
            end,
          validator_reward_ratio: Float.floor(candidate_reward_resp.validator_share / 10_000, 2),
          likelihood: ratio(likelihood[pool_staking_address] || 0, total_likelihood),
          validator_reward_percent: staking_resp.validator_reward_percent / 10_000,
          is_deleted: false,
          is_validator: is_validator[staking_resp.mining_address_hash] || false,
          is_unremovable: hash_to_string(pool_staking_address) == unremovable_validator,
          ban_reason: binary_to_string(mining_resp.ban_reason)
        }
        |> Map.merge(
          Map.take(staking_resp, [
            :is_active,
            :mining_address_hash,
            :self_staked_amount,
            :total_staked_amount
          ])
        )
        |> Map.merge(
          Map.take(mining_resp, [
            :are_delegators_banned,
            :banned_delegators_until,
            :banned_until,
            :is_banned,
            :was_banned_count,
            :was_validator_count
          ])
        )
      end)

    # form entries for writing to the `staking_pools_delegators` table in DB
    delegator_entries =
      Enum.map(staker_responses, fn {{pool_address, delegator_address, is_active}, response} ->
        delegator_reward_response = delegator_reward_responses[{pool_address, delegator_address, is_active}]

        Map.merge(response, %{
          address_hash: delegator_address,
          staking_address_hash: pool_address,
          is_active: is_active,
          reward_ratio: Float.floor(delegator_reward_response.delegator_share / 10_000, 2)
        })
      end)

    {:ok, _} =
      Chain.import(%{
        staking_pools: %{params: pool_entries},
        staking_pools_delegators: %{params: delegator_entries},
        timeout: :infinity
      })

    if start_snapshotting do
      spawn(StakeSnapshotting, :do_snapshotting, [
        %{contracts: contracts, abi: abi, epoch_number: global_responses.epoch_number, ets_table_name: @table_name},
        pool_staking_responses,
        pool_mining_responses,
        Map.new(Enum.map(staker_responses, fn {key, resp} -> {pool_staking_address, staker_address, _} = key; {{pool_staking_address, staker_address}, resp} end)),
        validators.pending, # mining addresses of pending validators
        mining_to_staking_address,
        block_number # the last block of the finished staking epoch
      ])
    end

    Publisher.broadcast(:staking_update)
  end

  defp get_token(address) do
    with {:ok, address_hash} <- Chain.string_to_address_hash(address),
         {:ok, token} <- Chain.token_from_address_hash(address_hash) do
      token
    else
      _ -> nil
    end
  end

  defp ratio(_numerator, 0), do: 0
  defp ratio(numerator, denominator), do: numerator / denominator * 100

  defp hash_to_string(hash), do: "0x" <> Base.encode16(hash, case: :lower)

  # sobelow_skip ["Traversal"]
  defp abi(file_name) do
    :explorer
    |> Application.app_dir("priv/contracts_abi/posdao/#{file_name}.json")
    |> File.read!()
    |> Jason.decode!()
  end

  defp binary_to_string(binary) do
    binary
    |> :binary.bin_to_list()
    |> Enum.filter(fn x -> x != 0 end)
    |> List.to_string()
  end
end