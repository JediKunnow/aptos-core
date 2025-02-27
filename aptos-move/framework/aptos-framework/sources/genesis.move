module aptos_framework::genesis {
    use std::error;
    use std::vector;

    use aptos_framework::account;
    use aptos_framework::aggregator_factory;
    use aptos_framework::aptos_coin::{Self, AptosCoin};
    use aptos_framework::aptos_governance;
    use aptos_framework::block;
    use aptos_framework::chain_id;
    use aptos_framework::chain_status;
    use aptos_framework::coin;
    use aptos_framework::consensus_config;
    use aptos_framework::gas_schedule;
    use aptos_framework::reconfiguration;
    use aptos_framework::stake;
    use aptos_framework::staking_config;
    use aptos_framework::state_storage;
    use aptos_framework::storage_gas;
    use aptos_framework::timestamp;
    use aptos_framework::transaction_fee;
    use aptos_framework::transaction_validation;
    use aptos_framework::version;

    const EDUPLICATE_ACCOUNT: u64 = 1;

    struct AccountMap has drop {
        account_address: address,
        balance: u64,
    }

    struct EmployeeAccountMap has copy, drop {
        accounts: vector<address>,
        validator: ValidatorConfigurationWithCommission,
        vesting_schedule_numerator: vector<u64>,
        vesting_schedule_denominator: u64,
    }

    struct ValidatorConfiguration has copy, drop {
        owner_address: address,
        operator_address: address,
        voter_address: address,
        stake_amount: u64,
        consensus_pubkey: vector<u8>,
        proof_of_possession: vector<u8>,
        network_addresses: vector<u8>,
        full_node_network_addresses: vector<u8>,
    }

    struct ValidatorConfigurationWithCommission has copy, drop {
        validator_config: ValidatorConfiguration,
        commission_percentage: u64,
    }

    /// Genesis step 1: Initialize aptos framework account and core modules on chain.
    fun initialize(
        gas_schedule: vector<u8>,
        chain_id: u8,
        initial_version: u64,
        consensus_config: vector<u8>,
        epoch_interval_microsecs: u64,
        minimum_stake: u64,
        maximum_stake: u64,
        recurring_lockup_duration_secs: u64,
        allow_validator_set_change: bool,
        rewards_rate: u64,
        rewards_rate_denominator: u64,
        voting_power_increase_limit: u64,
    ) {
        // Initialize the aptos framework account. This is the account where system resources and modules will be
        // deployed to. This will be entirely managed by on-chain governance and no entities have the key or privileges
        // to use this account.
        let (aptos_framework_account, aptos_framework_signer_cap) = account::create_framework_reserved_account(@aptos_framework);
        // Initialize account configs on aptos framework account.
        account::initialize(&aptos_framework_account);

        transaction_validation::initialize(
            &aptos_framework_account,
            b"script_prologue",
            b"module_prologue",
            b"multi_agent_script_prologue",
            b"epilogue",
        );

        // Give the decentralized on-chain governance control over the core framework account.
        aptos_governance::store_signer_cap(&aptos_framework_account, @aptos_framework, aptos_framework_signer_cap);

        // put reserved framework reserved accounts under aptos governance
        let framework_reserved_addresses = vector<address>[@0x2, @0x3, @0x4, @0x5, @0x6, @0x7, @0x8, @0x9, @0xa];
        let i = 0;
        while (!vector::is_empty(&framework_reserved_addresses)){
            let address = vector::pop_back<address>(&mut framework_reserved_addresses);
            let (aptos_account, framework_signer_cap) = account::create_framework_reserved_account(address);
            aptos_governance::store_signer_cap(&aptos_account, address, framework_signer_cap);
            i = i + 1;
        };


        consensus_config::initialize(&aptos_framework_account, consensus_config);
        version::initialize(&aptos_framework_account, initial_version);
        stake::initialize(&aptos_framework_account);
        staking_config::initialize(
            &aptos_framework_account,
            minimum_stake,
            maximum_stake,
            recurring_lockup_duration_secs,
            allow_validator_set_change,
            rewards_rate,
            rewards_rate_denominator,
            voting_power_increase_limit,
        );
        storage_gas::initialize(&aptos_framework_account);
        gas_schedule::initialize(&aptos_framework_account, gas_schedule);

        // Ensure we can create aggregators for supply, but not enable it for common use just yet.
        aggregator_factory::initialize_aggregator_factory(&aptos_framework_account);
        coin::initialize_supply_config(&aptos_framework_account);

        chain_id::initialize(&aptos_framework_account, chain_id);
        reconfiguration::initialize(&aptos_framework_account);
        block::initialize(&aptos_framework_account, epoch_interval_microsecs);
        state_storage::initialize(&aptos_framework_account);
        timestamp::set_time_has_started(&aptos_framework_account);
    }

    /// Genesis step 2: Initialize Aptos coin.
    fun initialize_aptos_coin(aptos_framework: &signer) {
        let (burn_cap, mint_cap) = aptos_coin::initialize(aptos_framework);
        // Give stake module MintCapability<AptosCoin> so it can mint rewards.
        stake::store_aptos_coin_mint_cap(aptos_framework, mint_cap);
        // Give transaction_fee module BurnCapability<AptosCoin> so it can burn gas.
        transaction_fee::store_aptos_coin_burn_cap(aptos_framework, burn_cap);
    }

    /// Only called for testnets and e2e tests.
    fun initialize_core_resources_and_aptos_coin(
        aptos_framework: &signer,
        core_resources_auth_key: vector<u8>,
    ) {
        let (burn_cap, mint_cap) = aptos_coin::initialize(aptos_framework);
        // Give stake module MintCapability<AptosCoin> so it can mint rewards.
        stake::store_aptos_coin_mint_cap(aptos_framework, mint_cap);
        // Give transaction_fee module BurnCapability<AptosCoin> so it can burn gas.
        transaction_fee::store_aptos_coin_burn_cap(aptos_framework, burn_cap);

        let core_resources = account::create_account(@core_resources);
        account::rotate_authentication_key_internal(&core_resources, core_resources_auth_key);
        aptos_coin::configure_accounts_for_test(aptos_framework, &core_resources, mint_cap);
    }

    fun create_accounts(aptos_framework: &signer, accounts: vector<AccountMap>) {
        let i = 0;
        let num_accounts = vector::length(&accounts);
        let unique_accounts = vector::empty();

        while (i < num_accounts) {
            let account_map = vector::borrow(&accounts, i);
            assert!(
                !vector::contains(&unique_accounts, &account_map.account_address),
                error::already_exists(EDUPLICATE_ACCOUNT),
            );
            vector::push_back(&mut unique_accounts, account_map.account_address);

            create_account(
                aptos_framework,
                account_map.account_address,
                account_map.balance,
            );

            i = i + 1;
        };
    }

    /// This creates an funds an account if it doesn't exist.
    /// If it exists, it just returns the signer.
    fun create_account(aptos_framework: &signer, account_address: address, balance: u64): signer {
        if (account::exists_at(account_address)) {
            create_signer(account_address)
        } else {
            let account = account::create_account(account_address);
            coin::register<AptosCoin>(&account);
            aptos_coin::mint(aptos_framework, account_address, balance);
            account
        }
    }

    fun create_employee_validators(
        _aptos_framework: &signer,
        _employees: vector<EmployeeAccountMap>,
    ) {
    }

    fun create_initialize_validators_with_commission(
        _aptos_framework: &signer,
        _validators: vector<ValidatorConfigurationWithCommission>) {
    }

    /// Sets up the initial validator set for the network.
    /// The validator "owner" accounts, and their authentication
    /// Addresses (and keys) are encoded in the `owners`
    /// Each validator signs consensus messages with the private key corresponding to the Ed25519
    /// public key in `consensus_pubkeys`.
    /// Finally, each validator must specify the network address
    /// (see types/src/network_address/mod.rs) for itself and its full nodes.
    ///
    /// Network address fields are a vector per account, where each entry is a vector of addresses
    /// encoded in a single BCS byte array.
    fun create_initialize_validators(aptos_framework: &signer, validators: vector<ValidatorConfiguration>) {
        let i = 0;
        let num_validators = vector::length(&validators);
        let unique_accounts = vector::empty();

        while (i < num_validators) {
            let validator = vector::borrow(&validators, i);

            assert!(
                !vector::contains(&unique_accounts, &validator.owner_address),
                error::already_exists(EDUPLICATE_ACCOUNT),
            );
            vector::push_back(&mut unique_accounts, validator.owner_address);

            let owner = &create_account(aptos_framework, validator.owner_address, validator.stake_amount);
            let operator = &create_account(aptos_framework, validator.operator_address, 0);
            create_account(aptos_framework, validator.voter_address, 0);

            // Initialize the stake pool and join the validator set.
            stake::initialize_stake_owner(
                owner,
                validator.stake_amount,
                validator.operator_address,
                validator.voter_address,
            );
            stake::rotate_consensus_key(
                operator,
                validator.owner_address,
                validator.consensus_pubkey,
                validator.proof_of_possession,
            );
            stake::update_network_and_fullnode_addresses(
                operator,
                validator.owner_address,
                validator.network_addresses,
                validator.full_node_network_addresses,
            );
            stake::join_validator_set_internal(operator, validator.owner_address);

            i = i + 1;
        };

        // Destroy the aptos framework account's ability to mint coins now that we're done with setting up the initial
        // validators.
        aptos_coin::destroy_mint_cap(aptos_framework);

        stake::on_new_epoch();
    }

    /// The last step of genesis.
    fun set_genesis_end(aptos_framework: &signer) {
        chain_status::set_genesis_end(aptos_framework);
    }

    native fun create_signer(addr: address): signer;

    #[verify_only]
    fun initialize_for_verification(
        gas_schedule: vector<u8>,
        chain_id: u8,
        initial_version: u64,
        consensus_config: vector<u8>,
        epoch_interval_microsecs: u64,
        minimum_stake: u64,
        maximum_stake: u64,
        recurring_lockup_duration_secs: u64,
        allow_validator_set_change: bool,
        rewards_rate: u64,
        rewards_rate_denominator: u64,
        voting_power_increase_limit: u64,

        aptos_framework: &signer,

        validators: vector<ValidatorConfiguration>,

        min_voting_threshold: u128,
        required_proposer_stake: u64,
        voting_duration_secs: u64,
    ) {
        initialize(
            gas_schedule,
            chain_id,
            initial_version,
            consensus_config,
            epoch_interval_microsecs,
            minimum_stake,
            maximum_stake,
            recurring_lockup_duration_secs,
            allow_validator_set_change,
            rewards_rate,
            rewards_rate_denominator,
            voting_power_increase_limit
        );

        initialize_aptos_coin(aptos_framework);

        aptos_governance::initialize_for_verification(
            aptos_framework,
            min_voting_threshold,
            required_proposer_stake,
            voting_duration_secs
        );

        create_initialize_validators(aptos_framework, validators);
        set_genesis_end(aptos_framework);
    }

    #[test_only]
    public fun setup() {
        initialize(
            x"000000000000000000", // empty gas schedule
            4u8, // TESTING chain ID
            0,
            x"12",
            1,
            0,
            1,
            1,
            true,
            1,
            1,
            30,
        )
    }

    #[test]
    fun test_setup() {
        setup();
        assert!(account::exists_at(@aptos_framework), 1);
        assert!(account::exists_at(@0x2), 1);
        assert!(account::exists_at(@0x3), 1);
        assert!(account::exists_at(@0x4), 1);
        assert!(account::exists_at(@0x5), 1);
        assert!(account::exists_at(@0x6), 1);
        assert!(account::exists_at(@0x7), 1);
        assert!(account::exists_at(@0x8), 1);
        assert!(account::exists_at(@0x9), 1);
        assert!(account::exists_at(@0xa), 1);
    }

    #[test(aptos_framework = @0x1)]
    fun test_create_account(aptos_framework: &signer) {
        setup();
        initialize_aptos_coin(aptos_framework);

        let addr = @0x121341; // 01 -> 0a are taken
        let test_signer_before = create_account(aptos_framework, addr, 15);
        let test_signer_after = create_account(aptos_framework, addr, 500);
        assert!(test_signer_before == test_signer_after, 0);
        assert!(coin::balance<AptosCoin>(addr) == 15, 1);
    }

    #[test(aptos_framework = @0x1)]
    fun test_create_accounts(aptos_framework: &signer) {
        setup();
        initialize_aptos_coin(aptos_framework);

        // 01 -> 0a are taken
        let addr0 = @0x121341;
        let addr1 = @0x121345;

        let accounts = vector[
            AccountMap {
                account_address: addr0,
                balance: 12345,
            },
            AccountMap {
                account_address: addr1,
                balance: 67890,
            },
        ];

        create_accounts(aptos_framework, accounts);
        assert!(coin::balance<AptosCoin>(addr0) == 12345, 0);
        assert!(coin::balance<AptosCoin>(addr1) == 67890, 1);

        create_account(aptos_framework, addr0, 23456);
        assert!(coin::balance<AptosCoin>(addr0) == 12345, 2);
    }
}
