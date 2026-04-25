/// AUFI Amplify Vault.
///
/// A standalone staking vault with a flat APR (default 8%) on staked AUFI.
/// Principal is locked for 30 days from each `stake` (or from each `reassign`
/// to a new artist). Accrued APR rewards are NOT paid into the staker's
/// wallet directly; instead they are routed into the staker's
/// `audiofi_user_vault` balance as a fresh 30-day-locked tranche, where
/// they behave identically to daily Pulse rewards: spendable on Fader AI
/// immediately, withdrawable to wallet after 30 days.
///
/// This module has no dependency on the off-chain oracle or
/// `audiofi_aufi_settlement`. The 8% APR is funded by `fund_reward_reserve`.
module audiofi::audiofi_amplify_vault {
    use std::bcs;
    use std::signer;
    use std::table;
    use std::vector;

    use supra_framework::event;
    use supra_framework::fungible_asset;
    use supra_framework::object;
    use supra_framework::primary_fungible_store;
    use supra_framework::timestamp;

    use audiofi::audiofi_user_vault;

    const AUFI_SEED: vector<u8> = b"TestAUFIv4";
    const VAULT_SEED: vector<u8> = b"AudioFiAmplifyVault";

    const E_NOT_ADMIN: u64 = 1;
    const E_NOT_INITIALIZED: u64 = 3;
    const E_PAUSED: u64 = 4;
    const E_ALREADY_INITIALIZED: u64 = 5;
    const E_ZERO_AMOUNT: u64 = 11;
    const E_LOCK_NOT_EXPIRED: u64 = 20;
    const E_POSITION_WITHDRAWN: u64 = 22;
    const E_SAME_ARTIST: u64 = 23;
    const E_NO_POSITIONS: u64 = 24;
    const E_INDEX_OUT_OF_BOUNDS: u64 = 25;
    const E_APR_OUT_OF_BOUNDS: u64 = 30;
    const E_RESERVE_INSUFFICIENT: u64 = 31;

    const BPS_DENOM: u64 = 10000;
    const FAN_WEIGHT_NUM: u64 = 7;
    const FAN_WEIGHT_DEN: u64 = 10;

    const LOCK_PERIOD_SECS: u64 = 30 * 24 * 60 * 60;
    const SECONDS_PER_YEAR: u64 = 365 * 24 * 60 * 60;

    const DEFAULT_APR_BPS: u64 = 800;
    const MIN_APR_BPS: u64 = 500;
    const MAX_APR_BPS: u64 = 2000;

    // --- Events ---

    #[event]
    struct AmplifyVaultInitializedEvent has drop, store {
        admin: address,
        system: address,
        apr_bps: u64,
        ts: u64,
    }

    #[event]
    struct AmplifyStakeEvent has drop, store {
        staker: address,
        artist: address,
        amount: u64,
        staked_at: u64,
        lock_expires_at: u64,
        is_self_stake: bool,
        ts: u64,
    }

    #[event]
    struct AmplifyHarvestEvent has drop, store {
        staker: address,
        artist: address,
        position_index: u64,
        reward_amount: u64,
        ts: u64,
    }

    #[event]
    struct AmplifyWithdrawEvent has drop, store {
        staker: address,
        artist: address,
        amount: u64,
        reward_amount: u64,
        ts: u64,
    }

    #[event]
    struct AmplifyReassignEvent has drop, store {
        staker: address,
        old_artist: address,
        new_artist: address,
        amount: u64,
        reward_amount: u64,
        new_lock_expiry: u64,
        ts: u64,
    }

    #[event]
    struct AmplifyAprUpdatedEvent has drop, store {
        old_apr_bps: u64,
        new_apr_bps: u64,
        ts: u64,
    }

    #[event]
    struct AmplifyReserveFundedEvent has drop, store {
        amount: u64,
        new_reserve_balance: u64,
        ts: u64,
    }

    // --- Data ---

    /// Per-stake position. We deliberately do NOT carry an
    /// `accumulated_rewards` field: every state-changing call
    /// (`harvest_rewards`, `reassign`, `withdraw`) flushes pending
    /// APR into the user vault as a locked tranche before mutating the
    /// position, so the position's only reward bookkeeping is the
    /// `last_reward_timestamp` watermark.
    struct Position has store, drop, copy {
        amount: u64,
        assigned_artist: address,
        staked_at: u64,
        lock_expires_at: u64,
        last_reward_timestamp: u64,
        withdrawn: bool,
    }

    struct ArtistStake has store, drop, copy {
        self_stake: u64,
        fan_stake: u64,
    }

    struct Config has key {
        admin: address,
        system: address,
        paused: bool,

        amplify_apr_bps: u64,

        /// Total of all live (un-withdrawn) staked principal. Backed
        /// by AUFI sitting in the vault object's primary fungible store.
        total_principal: u64,

        /// Available APR funding. Also backed by AUFI in the vault
        /// object's primary store; principal and reserve share the same
        /// store but are accounted separately so the contract can never
        /// pay APR using staker principal.
        reward_reserve_balance: u64,

        user_positions: table::Table<vector<u8>, vector<Position>>,
        artist_stakes: table::Table<vector<u8>, ArtistStake>,
        artist_boost_scores: table::Table<vector<u8>, u64>,

        /// Signer cap for the vault object that holds AUFI.
        vault_extend_ref: object::ExtendRef,
    }

    // --- Helpers ---

    public fun key_addr(a: address): vector<u8> { bcs::to_bytes(&a) }

    fun get_aufi_metadata(): object::Object<fungible_asset::Metadata> {
        let addr = object::create_object_address(&@audiofi, AUFI_SEED);
        object::address_to_object<fungible_asset::Metadata>(addr)
    }

    fun get_vault_address(): address {
        object::create_object_address(&@audiofi, VAULT_SEED)
    }

    fun assert_initialized(admin_addr: address) {
        assert!(exists<Config>(admin_addr), E_NOT_INITIALIZED);
    }

    fun assert_admin(cfg: &Config, caller: address) {
        assert!(caller == cfg.admin, E_NOT_ADMIN);
    }

    fun sqrt_u64(x: u64): u64 {
        if (x == 0) return 0;
        let z = x;
        let y = (z + 1) / 2;
        while (y < z) { z = y; y = (x / y + y) / 2; };
        z
    }

    fun get_artist_stake(cfg: &Config, artist: address): (u64, u64) {
        let k = key_addr(artist);
        if (table::contains(&cfg.artist_stakes, k)) {
            let s = table::borrow(&cfg.artist_stakes, k);
            (s.self_stake, s.fan_stake)
        } else { (0, 0) }
    }

    fun compute_boost(self_stake: u64, fan_stake: u64): u64 {
        let weighted_fan = fan_stake * FAN_WEIGHT_NUM / FAN_WEIGHT_DEN;
        sqrt_u64(self_stake + weighted_fan)
    }

    fun compute_pending_reward(amount: u64, apr_bps: u64, last_ts: u64, now: u64): u64 {
        if (now <= last_ts) return 0;
        let elapsed = now - last_ts;
        let numerator = (amount as u128) * (apr_bps as u128) * (elapsed as u128);
        let denominator = (BPS_DENOM as u128) * (SECONDS_PER_YEAR as u128);
        ((numerator / denominator) as u64)
    }

    fun update_artist_boost(cfg: &mut Config, artist: address) {
        let k = key_addr(artist);
        let (ss, fs) = get_artist_stake(cfg, artist);
        let boost = compute_boost(ss, fs);
        if (table::contains(&cfg.artist_boost_scores, k)) {
            *table::borrow_mut(&mut cfg.artist_boost_scores, k) = boost;
        } else {
            table::add(&mut cfg.artist_boost_scores, k, boost);
        };
    }

    fun add_artist_stake_internal(
        cfg: &mut Config, artist: address, amount: u64, is_self: bool
    ) {
        let k = key_addr(artist);
        if (table::contains(&cfg.artist_stakes, k)) {
            let s = table::borrow_mut(&mut cfg.artist_stakes, k);
            if (is_self) { s.self_stake = s.self_stake + amount; }
            else { s.fan_stake = s.fan_stake + amount; };
        } else {
            let ss = if (is_self) amount else 0;
            let fs = if (is_self) 0 else amount;
            table::add(&mut cfg.artist_stakes, k, ArtistStake { self_stake: ss, fan_stake: fs });
        };
    }

    fun sub_artist_stake_internal(
        cfg: &mut Config, artist: address, amount: u64, is_self: bool
    ) {
        let k = key_addr(artist);
        if (table::contains(&cfg.artist_stakes, k)) {
            let s = table::borrow_mut(&mut cfg.artist_stakes, k);
            if (is_self) { s.self_stake = s.self_stake - amount; }
            else { s.fan_stake = s.fan_stake - amount; };
        };
    }

    /// Move `amount` AUFI from the amplify vault object into the user
    /// vault as a fresh 30-day-locked tranche. Caps `amount` at
    /// `reward_reserve_balance`; returns the actually-paid amount.
    fun route_reward_to_user_vault(
        cfg: &mut Config,
        staker_addr: address,
        amount: u64,
    ): u64 {
        if (amount == 0) return 0;
        let payable = if (amount > cfg.reward_reserve_balance) {
            cfg.reward_reserve_balance
        } else { amount };
        if (payable == 0) return 0;

        cfg.reward_reserve_balance = cfg.reward_reserve_balance - payable;

        let vault_signer = object::generate_signer_for_extending(&cfg.vault_extend_ref);
        audiofi_user_vault::deposit_locked_tranche(&vault_signer, staker_addr, payable);

        payable
    }

    // --- Initialize ---

    public entry fun initialize(
        admin_signer: &signer,
        system: address,
    ) {
        let admin = signer::address_of(admin_signer);
        assert!(!exists<Config>(admin), E_ALREADY_INITIALIZED);
        let now = timestamp::now_seconds();

        let constructor_ref = object::create_named_object(admin_signer, VAULT_SEED);
        let extend_ref = object::generate_extend_ref(&constructor_ref);

        let vault_addr = object::address_from_constructor_ref(&constructor_ref);
        let metadata = get_aufi_metadata();
        primary_fungible_store::ensure_primary_store_exists(vault_addr, metadata);

        move_to(admin_signer, Config {
            admin,
            system,
            paused: false,
            amplify_apr_bps: DEFAULT_APR_BPS,
            total_principal: 0,
            reward_reserve_balance: 0,
            user_positions: table::new<vector<u8>, vector<Position>>(),
            artist_stakes: table::new<vector<u8>, ArtistStake>(),
            artist_boost_scores: table::new<vector<u8>, u64>(),
            vault_extend_ref: extend_ref,
        });

        event::emit(AmplifyVaultInitializedEvent { admin, system, apr_bps: DEFAULT_APR_BPS, ts: now });
    }

    // --- Admin ---

    public entry fun set_amplify_apr(
        caller: &signer,
        admin_addr: address,
        new_apr_bps: u64,
    ) acquires Config {
        assert_initialized(admin_addr);
        assert!(new_apr_bps >= MIN_APR_BPS && new_apr_bps <= MAX_APR_BPS, E_APR_OUT_OF_BOUNDS);

        let cfg = borrow_global_mut<Config>(admin_addr);
        assert_admin(cfg, signer::address_of(caller));

        let old = cfg.amplify_apr_bps;
        cfg.amplify_apr_bps = new_apr_bps;

        event::emit(AmplifyAprUpdatedEvent {
            old_apr_bps: old,
            new_apr_bps,
            ts: timestamp::now_seconds(),
        });
    }

    public entry fun set_paused(
        caller: &signer, admin_addr: address, paused: bool,
    ) acquires Config {
        assert_initialized(admin_addr);
        let cfg = borrow_global_mut<Config>(admin_addr);
        assert_admin(cfg, signer::address_of(caller));
        cfg.paused = paused;
    }

    /// Anyone can fund the APR reserve. AUFI is moved from the funder's
    /// primary store into the amplify vault object.
    public entry fun fund_reward_reserve(
        funder: &signer,
        admin_addr: address,
        amount: u64,
    ) acquires Config {
        assert_initialized(admin_addr);
        assert!(amount > 0, E_ZERO_AMOUNT);

        let metadata = get_aufi_metadata();
        let vault_addr = get_vault_address();
        primary_fungible_store::transfer(funder, metadata, vault_addr, amount);

        let cfg = borrow_global_mut<Config>(admin_addr);
        cfg.reward_reserve_balance = cfg.reward_reserve_balance + amount;

        event::emit(AmplifyReserveFundedEvent {
            amount,
            new_reserve_balance: cfg.reward_reserve_balance,
            ts: timestamp::now_seconds(),
        });
    }

    // --- Stake ---

    public entry fun stake(
        staker: &signer,
        admin_addr: address,
        amount: u64,
        assigned_artist: address,
    ) acquires Config {
        assert_initialized(admin_addr);
        assert!(amount > 0, E_ZERO_AMOUNT);

        let staker_addr = signer::address_of(staker);
        let now = timestamp::now_seconds();
        let is_self = staker_addr == assigned_artist;
        let lock_expires = now + LOCK_PERIOD_SECS;

        let metadata = get_aufi_metadata();
        let vault_addr = get_vault_address();
        primary_fungible_store::transfer(staker, metadata, vault_addr, amount);

        let cfg = borrow_global_mut<Config>(admin_addr);
        assert!(!cfg.paused, E_PAUSED);

        cfg.total_principal = cfg.total_principal + amount;

        let pos = Position {
            amount,
            assigned_artist,
            staked_at: now,
            lock_expires_at: lock_expires,
            last_reward_timestamp: now,
            withdrawn: false,
        };

        let k = key_addr(staker_addr);
        if (table::contains(&cfg.user_positions, k)) {
            vector::push_back(table::borrow_mut(&mut cfg.user_positions, k), pos);
        } else {
            let v = vector::empty<Position>();
            vector::push_back(&mut v, pos);
            table::add(&mut cfg.user_positions, k, v);
        };

        add_artist_stake_internal(cfg, assigned_artist, amount, is_self);
        update_artist_boost(cfg, assigned_artist);

        event::emit(AmplifyStakeEvent {
            staker: staker_addr, artist: assigned_artist, amount,
            staked_at: now, lock_expires_at: lock_expires, is_self_stake: is_self, ts: now,
        });
    }

    // --- Harvest accrued APR mid-stake (no principal movement) ---

    /// Flush the position's pending APR into the staker's user_vault as a
    /// fresh 30-day-locked tranche. Anyone can call on behalf of any
    /// staker; the rewards always land in the staker's user vault.
    public entry fun harvest_rewards(
        _caller: &signer,
        admin_addr: address,
        staker_addr: address,
        position_index: u64,
    ) acquires Config {
        assert_initialized(admin_addr);
        let now = timestamp::now_seconds();

        let cfg = borrow_global_mut<Config>(admin_addr);
        assert!(!cfg.paused, E_PAUSED);

        let k = key_addr(staker_addr);
        assert!(table::contains(&cfg.user_positions, k), E_NO_POSITIONS);

        let (amount, artist, last_ts) = {
            let positions = table::borrow(&cfg.user_positions, k);
            assert!(position_index < vector::length(positions), E_INDEX_OUT_OF_BOUNDS);
            let pos = vector::borrow(positions, position_index);
            assert!(!pos.withdrawn, E_POSITION_WITHDRAWN);
            (pos.amount, pos.assigned_artist, pos.last_reward_timestamp)
        };

        let pending = compute_pending_reward(amount, cfg.amplify_apr_bps, last_ts, now);
        let paid = route_reward_to_user_vault(cfg, staker_addr, pending);

        let positions_mut = table::borrow_mut(&mut cfg.user_positions, k);
        let pos_mut = vector::borrow_mut(positions_mut, position_index);
        pos_mut.last_reward_timestamp = now;

        event::emit(AmplifyHarvestEvent {
            staker: staker_addr,
            artist,
            position_index,
            reward_amount: paid,
            ts: now,
        });
    }

    // --- Withdraw (after 30-day lock) ---

    public entry fun withdraw(
        staker: &signer,
        admin_addr: address,
        position_index: u64,
    ) acquires Config {
        assert_initialized(admin_addr);
        let staker_addr = signer::address_of(staker);
        let now = timestamp::now_seconds();

        let cfg = borrow_global_mut<Config>(admin_addr);
        assert!(!cfg.paused, E_PAUSED);

        let k = key_addr(staker_addr);
        assert!(table::contains(&cfg.user_positions, k), E_NO_POSITIONS);

        let (amount, artist, last_ts) = {
            let positions = table::borrow(&cfg.user_positions, k);
            assert!(position_index < vector::length(positions), E_INDEX_OUT_OF_BOUNDS);
            let pos = vector::borrow(positions, position_index);
            assert!(!pos.withdrawn, E_POSITION_WITHDRAWN);
            assert!(now >= pos.lock_expires_at, E_LOCK_NOT_EXPIRED);
            (pos.amount, pos.assigned_artist, pos.last_reward_timestamp)
        };

        let pending = compute_pending_reward(amount, cfg.amplify_apr_bps, last_ts, now);
        let reward_paid = route_reward_to_user_vault(cfg, staker_addr, pending);

        let is_self = staker_addr == artist;
        cfg.total_principal = cfg.total_principal - amount;
        sub_artist_stake_internal(cfg, artist, amount, is_self);
        update_artist_boost(cfg, artist);

        {
            let positions_mut = table::borrow_mut(&mut cfg.user_positions, k);
            let pos_mut = vector::borrow_mut(positions_mut, position_index);
            pos_mut.withdrawn = true;
            pos_mut.last_reward_timestamp = now;
        };

        let vault_signer = object::generate_signer_for_extending(&cfg.vault_extend_ref);
        let metadata = get_aufi_metadata();
        primary_fungible_store::transfer(&vault_signer, metadata, staker_addr, amount);

        event::emit(AmplifyWithdrawEvent {
            staker: staker_addr, artist, amount, reward_amount: reward_paid, ts: now,
        });
    }

    // --- Reassign ---

    public entry fun reassign(
        staker: &signer,
        admin_addr: address,
        position_index: u64,
        new_artist: address,
    ) acquires Config {
        assert_initialized(admin_addr);
        let staker_addr = signer::address_of(staker);
        let now = timestamp::now_seconds();

        let cfg = borrow_global_mut<Config>(admin_addr);
        assert!(!cfg.paused, E_PAUSED);

        let k = key_addr(staker_addr);
        assert!(table::contains(&cfg.user_positions, k), E_NO_POSITIONS);

        let (old_artist, amount, was_self, is_self_new, last_ts) = {
            let positions = table::borrow(&cfg.user_positions, k);
            assert!(position_index < vector::length(positions), E_INDEX_OUT_OF_BOUNDS);
            let pos = vector::borrow(positions, position_index);
            assert!(!pos.withdrawn, E_POSITION_WITHDRAWN);
            assert!(now >= pos.lock_expires_at, E_LOCK_NOT_EXPIRED);
            let oa = pos.assigned_artist;
            assert!(oa != new_artist, E_SAME_ARTIST);
            (oa, pos.amount, staker_addr == oa, staker_addr == new_artist, pos.last_reward_timestamp)
        };

        let pending = compute_pending_reward(amount, cfg.amplify_apr_bps, last_ts, now);
        let reward_paid = route_reward_to_user_vault(cfg, staker_addr, pending);

        sub_artist_stake_internal(cfg, old_artist, amount, was_self);
        update_artist_boost(cfg, old_artist);
        add_artist_stake_internal(cfg, new_artist, amount, is_self_new);
        update_artist_boost(cfg, new_artist);

        let new_lock = now + LOCK_PERIOD_SECS;
        let positions_mut = table::borrow_mut(&mut cfg.user_positions, k);
        let pos_mut = vector::borrow_mut(positions_mut, position_index);
        pos_mut.assigned_artist = new_artist;
        pos_mut.lock_expires_at = new_lock;
        pos_mut.last_reward_timestamp = now;

        event::emit(AmplifyReassignEvent {
            staker: staker_addr,
            old_artist,
            new_artist,
            amount,
            reward_amount: reward_paid,
            new_lock_expiry: new_lock,
            ts: now,
        });
    }

    // --- Sweep unused reserve (admin only) ---

    /// Allow the admin to recover unused APR reserve back to a chosen
    /// recipient (e.g. for migrations or to top up a different reward
    /// program). Cannot touch staker principal: the sweep is bounded by
    /// `reward_reserve_balance`.
    public entry fun sweep_reserve(
        admin_signer: &signer,
        admin_addr: address,
        recipient: address,
        amount: u64,
    ) acquires Config {
        assert_initialized(admin_addr);
        let cfg = borrow_global_mut<Config>(admin_addr);
        assert_admin(cfg, signer::address_of(admin_signer));
        assert!(amount > 0, E_ZERO_AMOUNT);
        assert!(amount <= cfg.reward_reserve_balance, E_RESERVE_INSUFFICIENT);

        cfg.reward_reserve_balance = cfg.reward_reserve_balance - amount;

        let vault_signer = object::generate_signer_for_extending(&cfg.vault_extend_ref);
        let metadata = get_aufi_metadata();
        primary_fungible_store::transfer(&vault_signer, metadata, recipient, amount);
    }

    // --- Views ---

    #[view]
    public fun view_apr_bps(admin_addr: address): u64 acquires Config {
        borrow_global<Config>(admin_addr).amplify_apr_bps
    }

    #[view]
    public fun view_total_staked(admin_addr: address): u64 acquires Config {
        borrow_global<Config>(admin_addr).total_principal
    }

    #[view]
    public fun view_reward_reserve(admin_addr: address): u64 acquires Config {
        borrow_global<Config>(admin_addr).reward_reserve_balance
    }

    #[view]
    public fun view_artist_stake(admin_addr: address, artist: address): (u64, u64) acquires Config {
        get_artist_stake(borrow_global<Config>(admin_addr), artist)
    }

    #[view]
    public fun view_boost_score(admin_addr: address, artist: address): u64 acquires Config {
        let cfg = borrow_global<Config>(admin_addr);
        let k = key_addr(artist);
        if (table::contains(&cfg.artist_boost_scores, k)) { *table::borrow(&cfg.artist_boost_scores, k) } else { 0 }
    }

    #[view]
    public fun view_user_position_count(admin_addr: address, user: address): u64 acquires Config {
        let cfg = borrow_global<Config>(admin_addr);
        let k = key_addr(user);
        if (table::contains(&cfg.user_positions, k)) { vector::length(table::borrow(&cfg.user_positions, k)) } else { 0 }
    }

    #[view]
    public fun view_user_position(
        admin_addr: address, user: address, index: u64
    ): (u64, address, u64, u64, u64, bool) acquires Config {
        let cfg = borrow_global<Config>(admin_addr);
        let k = key_addr(user);
        assert!(table::contains(&cfg.user_positions, k), E_NO_POSITIONS);
        let positions = table::borrow(&cfg.user_positions, k);
        assert!(index < vector::length(positions), E_INDEX_OUT_OF_BOUNDS);
        let pos = vector::borrow(positions, index);
        (pos.amount, pos.assigned_artist, pos.staked_at, pos.lock_expires_at,
         pos.last_reward_timestamp, pos.withdrawn)
    }

    #[view]
    public fun view_pending_reward(
        admin_addr: address, user: address, index: u64
    ): u64 acquires Config {
        let cfg = borrow_global<Config>(admin_addr);
        let k = key_addr(user);
        assert!(table::contains(&cfg.user_positions, k), E_NO_POSITIONS);
        let positions = table::borrow(&cfg.user_positions, k);
        assert!(index < vector::length(positions), E_INDEX_OUT_OF_BOUNDS);
        let pos = vector::borrow(positions, index);
        if (pos.withdrawn) return 0;
        compute_pending_reward(pos.amount, cfg.amplify_apr_bps, pos.last_reward_timestamp, timestamp::now_seconds())
    }

    #[view]
    public fun vault_address(): address {
        get_vault_address()
    }
}
