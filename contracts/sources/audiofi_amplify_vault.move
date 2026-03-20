module audiofi::audiofi_amplify_vault {
    use std::bcs;
    use std::signer;
    use std::table;
    use std::vector;

    use supra_framework::coin;
    use supra_framework::event;
    use supra_framework::timestamp;

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

    const BPS_DENOM: u64 = 10000;
    const FAN_WEIGHT_NUM: u64 = 7;
    const FAN_WEIGHT_DEN: u64 = 10;

    const LOCK_PERIOD_SECS: u64 = 30 * 24 * 60 * 60; // 30 days
    const SECONDS_PER_YEAR: u64 = 365 * 24 * 60 * 60;

    const DEFAULT_APR_BPS: u64 = 1200; // 12%
    const MIN_APR_BPS: u64 = 500;      // 5%
    const MAX_APR_BPS: u64 = 2000;     // 20%

    // ─── Events ────────────────────────────────────────────────

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
        new_lock_expiry: u64,
        ts: u64,
    }

    #[event]
    struct AmplifyAprUpdatedEvent has drop, store {
        old_apr_bps: u64,
        new_apr_bps: u64,
        ts: u64,
    }

    // ─── Data Structures ───────────────────────────────────────

    struct Position has store, drop, copy {
        amount: u64,
        assigned_artist: address,
        staked_at: u64,
        lock_expires_at: u64,
        last_reward_timestamp: u64,
        accumulated_rewards: u64,
        withdrawn: bool,
    }

    struct ArtistStake has store, drop, copy {
        self_stake: u64,
        fan_stake: u64,
    }

    struct Config<phantom CoinType> has key {
        admin: address,
        system: address,
        burn_address: address,
        paused: bool,

        amplify_apr_bps: u64,

        total_vault_balance: u64,

        user_positions: table::Table<vector<u8>, vector<Position>>,
        artist_stakes: table::Table<vector<u8>, ArtistStake>,
        artist_boost_scores: table::Table<vector<u8>, u64>,

        vault: coin::Coin<CoinType>,
        reward_reserve: coin::Coin<CoinType>,
    }

    // ─── Helpers ────────────────────────────────────────────────

    public fun key_addr(a: address): vector<u8> { bcs::to_bytes(&a) }

    fun assert_initialized<CoinType>(admin_addr: address) {
        assert!(exists<Config<CoinType>>(admin_addr), E_NOT_INITIALIZED);
    }

    fun assert_admin<CoinType>(cfg: &Config<CoinType>, caller: address) {
        assert!(caller == cfg.admin, E_NOT_ADMIN);
    }

    fun sqrt_u64(x: u64): u64 {
        if (x == 0) return 0;
        let z = x;
        let y = (z + 1) / 2;
        while (y < z) { z = y; y = (x / y + y) / 2; };
        z
    }

    fun get_artist_stake<CoinType>(cfg: &Config<CoinType>, artist: address): (u64, u64) {
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
        // reward = amount * apr_bps / BPS_DENOM * elapsed / SECONDS_PER_YEAR
        // reordered for precision: (amount * apr_bps * elapsed) / (BPS_DENOM * SECONDS_PER_YEAR)
        let numerator = (amount as u128) * (apr_bps as u128) * (elapsed as u128);
        let denominator = (BPS_DENOM as u128) * (SECONDS_PER_YEAR as u128);
        ((numerator / denominator) as u64)
    }

    fun update_artist_boost<CoinType>(cfg: &mut Config<CoinType>, artist: address) {
        let k = key_addr(artist);
        let (ss, fs) = get_artist_stake(cfg, artist);
        let boost = compute_boost(ss, fs);
        if (table::contains(&cfg.artist_boost_scores, k)) {
            *table::borrow_mut(&mut cfg.artist_boost_scores, k) = boost;
        } else {
            table::add(&mut cfg.artist_boost_scores, k, boost);
        };
    }

    fun add_artist_stake_internal<CoinType>(
        cfg: &mut Config<CoinType>, artist: address, amount: u64, is_self: bool
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

    fun sub_artist_stake_internal<CoinType>(
        cfg: &mut Config<CoinType>, artist: address, amount: u64, is_self: bool
    ) {
        let k = key_addr(artist);
        if (table::contains(&cfg.artist_stakes, k)) {
            let s = table::borrow_mut(&mut cfg.artist_stakes, k);
            if (is_self) { s.self_stake = s.self_stake - amount; }
            else { s.fan_stake = s.fan_stake - amount; };
        };
    }

    // ─── Initialize ────────────────────────────────────────────

    public entry fun initialize<CoinType>(
        admin_signer: &signer,
        system: address,
        burn_address: address,
    ) {
        let admin = signer::address_of(admin_signer);
        assert!(!exists<Config<CoinType>>(admin), E_ALREADY_INITIALIZED);
        let now = timestamp::now_seconds();

        move_to(admin_signer, Config<CoinType> {
            admin,
            system,
            burn_address,
            paused: false,
            amplify_apr_bps: DEFAULT_APR_BPS,
            total_vault_balance: 0,
            user_positions: table::new<vector<u8>, vector<Position>>(),
            artist_stakes: table::new<vector<u8>, ArtistStake>(),
            artist_boost_scores: table::new<vector<u8>, u64>(),
            vault: coin::zero<CoinType>(),
            reward_reserve: coin::zero<CoinType>(),
        });

        event::emit(AmplifyVaultInitializedEvent { admin, system, apr_bps: DEFAULT_APR_BPS, ts: now });
    }

    // ─── Admin: Set APR ────────────────────────────────────────

    public entry fun set_amplify_apr<CoinType>(
        caller: &signer,
        admin_addr: address,
        new_apr_bps: u64,
    ) acquires Config {
        assert_initialized<CoinType>(admin_addr);
        assert!(new_apr_bps >= MIN_APR_BPS && new_apr_bps <= MAX_APR_BPS, E_APR_OUT_OF_BOUNDS);

        let cfg = borrow_global_mut<Config<CoinType>>(admin_addr);
        assert_admin(cfg, signer::address_of(caller));

        let old = cfg.amplify_apr_bps;
        cfg.amplify_apr_bps = new_apr_bps;

        event::emit(AmplifyAprUpdatedEvent {
            old_apr_bps: old,
            new_apr_bps,
            ts: timestamp::now_seconds(),
        });
    }

    // ─── Admin: Fund Reward Reserve ────────────────────────────

    public entry fun fund_reward_reserve<CoinType>(
        funder: &signer,
        admin_addr: address,
        amount: u64,
    ) acquires Config {
        assert_initialized<CoinType>(admin_addr);
        assert!(amount > 0, E_ZERO_AMOUNT);
        let payment = coin::withdraw<CoinType>(funder, amount);
        let cfg = borrow_global_mut<Config<CoinType>>(admin_addr);
        coin::merge(&mut cfg.reward_reserve, payment);
    }

    // ─── Stake ─────────────────────────────────────────────────

    public entry fun stake<CoinType>(
        staker: &signer,
        admin_addr: address,
        amount: u64,
        assigned_artist: address,
    ) acquires Config {
        assert_initialized<CoinType>(admin_addr);
        assert!(amount > 0, E_ZERO_AMOUNT);

        let staker_addr = signer::address_of(staker);
        let now = timestamp::now_seconds();
        let is_self = staker_addr == assigned_artist;
        let lock_expires = now + LOCK_PERIOD_SECS;

        let payment = coin::withdraw<CoinType>(staker, amount);
        let cfg = borrow_global_mut<Config<CoinType>>(admin_addr);
        assert!(!cfg.paused, E_PAUSED);

        coin::merge(&mut cfg.vault, payment);
        cfg.total_vault_balance = cfg.total_vault_balance + amount;

        let pos = Position {
            amount,
            assigned_artist,
            staked_at: now,
            lock_expires_at: lock_expires,
            last_reward_timestamp: now,
            accumulated_rewards: 0,
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

    // ─── Withdraw (after 30-day lock) — pays principal + accrued rewards

    public entry fun withdraw<CoinType>(
        staker: &signer,
        admin_addr: address,
        position_index: u64,
    ) acquires Config {
        assert_initialized<CoinType>(admin_addr);
        let staker_addr = signer::address_of(staker);
        let now = timestamp::now_seconds();

        let cfg = borrow_global_mut<Config<CoinType>>(admin_addr);
        assert!(!cfg.paused, E_PAUSED);

        let k = key_addr(staker_addr);
        assert!(table::contains(&cfg.user_positions, k), E_NO_POSITIONS);

        let positions = table::borrow_mut(&mut cfg.user_positions, k);
        let len = vector::length(positions);
        assert!(position_index < len, E_INDEX_OUT_OF_BOUNDS);

        let pos = vector::borrow_mut(positions, position_index);
        assert!(!pos.withdrawn, E_POSITION_WITHDRAWN);
        assert!(now >= pos.lock_expires_at, E_LOCK_NOT_EXPIRED);

        // Calculate accrued APR rewards
        let pending = compute_pending_reward(pos.amount, cfg.amplify_apr_bps, pos.last_reward_timestamp, now);
        let reward_paid: u64 = 0;
        if (pending > 0) {
            let reserve_balance = coin::value(&cfg.reward_reserve);
            reward_paid = if (pending > reserve_balance) { reserve_balance } else { pending };
            if (reward_paid > 0) {
                pos.accumulated_rewards = pos.accumulated_rewards + reward_paid;
                let reward_coin = coin::extract(&mut cfg.reward_reserve, reward_paid);
                coin::deposit<CoinType>(staker_addr, reward_coin);
            };
        };

        let amount = pos.amount;
        let artist = pos.assigned_artist;
        let is_self = staker_addr == artist;
        pos.withdrawn = true;
        pos.last_reward_timestamp = now;

        cfg.total_vault_balance = cfg.total_vault_balance - amount;
        sub_artist_stake_internal(cfg, artist, amount, is_self);
        update_artist_boost(cfg, artist);

        let payout = coin::extract(&mut cfg.vault, amount);
        coin::deposit<CoinType>(staker_addr, payout);

        event::emit(AmplifyWithdrawEvent {
            staker: staker_addr, artist, amount, reward_amount: reward_paid, ts: now,
        });
    }

    // ─── Reassign ──────────────────────────────────────────────

    public entry fun reassign<CoinType>(
        staker: &signer,
        admin_addr: address,
        position_index: u64,
        new_artist: address,
    ) acquires Config {
        assert_initialized<CoinType>(admin_addr);
        let staker_addr = signer::address_of(staker);
        let now = timestamp::now_seconds();

        let cfg = borrow_global_mut<Config<CoinType>>(admin_addr);
        assert!(!cfg.paused, E_PAUSED);

        let k = key_addr(staker_addr);
        assert!(table::contains(&cfg.user_positions, k), E_NO_POSITIONS);

        let (old_artist, amount, was_self, is_self_new) = {
            let positions = table::borrow(&cfg.user_positions, k);
            let len = vector::length(positions);
            assert!(position_index < len, E_INDEX_OUT_OF_BOUNDS);
            let pos = vector::borrow(positions, position_index);
            assert!(!pos.withdrawn, E_POSITION_WITHDRAWN);
            assert!(now >= pos.lock_expires_at, E_LOCK_NOT_EXPIRED);
            let oa = pos.assigned_artist;
            assert!(oa != new_artist, E_SAME_ARTIST);
            (oa, pos.amount, staker_addr == oa, staker_addr == new_artist)
        };

        sub_artist_stake_internal(cfg, old_artist, amount, was_self);
        update_artist_boost(cfg, old_artist);
        add_artist_stake_internal(cfg, new_artist, amount, is_self_new);
        update_artist_boost(cfg, new_artist);

        let new_lock = now + LOCK_PERIOD_SECS;
        let positions_mut = table::borrow_mut(&mut cfg.user_positions, k);
        let pos_mut = vector::borrow_mut(positions_mut, position_index);

        // Accrue rewards up to now before reassigning
        let pending = compute_pending_reward(pos_mut.amount, cfg.amplify_apr_bps, pos_mut.last_reward_timestamp, now);
        pos_mut.accumulated_rewards = pos_mut.accumulated_rewards + pending;

        pos_mut.assigned_artist = new_artist;
        pos_mut.lock_expires_at = new_lock;
        pos_mut.last_reward_timestamp = now;

        event::emit(AmplifyReassignEvent {
            staker: staker_addr, old_artist, new_artist, amount,
            new_lock_expiry: new_lock, ts: now,
        });
    }

    // ─── Admin ─────────────────────────────────────────────────

    public entry fun set_paused<CoinType>(
        caller: &signer, admin_addr: address, paused: bool,
    ) acquires Config {
        assert_initialized<CoinType>(admin_addr);
        let cfg = borrow_global_mut<Config<CoinType>>(admin_addr);
        assert_admin(cfg, signer::address_of(caller));
        cfg.paused = paused;
    }

    // ─── Views ─────────────────────────────────────────────────

    #[view]
    public fun view_apr_bps<CoinType>(admin_addr: address): u64 acquires Config {
        borrow_global<Config<CoinType>>(admin_addr).amplify_apr_bps
    }

    #[view]
    public fun view_total_staked<CoinType>(admin_addr: address): u64 acquires Config {
        borrow_global<Config<CoinType>>(admin_addr).total_vault_balance
    }

    #[view]
    public fun view_reward_reserve<CoinType>(admin_addr: address): u64 acquires Config {
        coin::value(&borrow_global<Config<CoinType>>(admin_addr).reward_reserve)
    }

    #[view]
    public fun view_artist_stake<CoinType>(admin_addr: address, artist: address): (u64, u64) acquires Config {
        get_artist_stake(borrow_global<Config<CoinType>>(admin_addr), artist)
    }

    #[view]
    public fun view_boost_score<CoinType>(admin_addr: address, artist: address): u64 acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);
        let k = key_addr(artist);
        if (table::contains(&cfg.artist_boost_scores, k)) { *table::borrow(&cfg.artist_boost_scores, k) } else { 0 }
    }

    #[view]
    public fun view_user_position_count<CoinType>(admin_addr: address, user: address): u64 acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);
        let k = key_addr(user);
        if (table::contains(&cfg.user_positions, k)) { vector::length(table::borrow(&cfg.user_positions, k)) } else { 0 }
    }

    #[view]
    public fun view_user_position<CoinType>(
        admin_addr: address, user: address, index: u64
    ): (u64, address, u64, u64, u64, u64, bool) acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);
        let k = key_addr(user);
        assert!(table::contains(&cfg.user_positions, k), E_NO_POSITIONS);
        let positions = table::borrow(&cfg.user_positions, k);
        assert!(index < vector::length(positions), E_INDEX_OUT_OF_BOUNDS);
        let pos = vector::borrow(positions, index);
        (pos.amount, pos.assigned_artist, pos.staked_at, pos.lock_expires_at,
         pos.last_reward_timestamp, pos.accumulated_rewards, pos.withdrawn)
    }

    #[view]
    public fun view_pending_reward<CoinType>(
        admin_addr: address, user: address, index: u64
    ): u64 acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);
        let k = key_addr(user);
        assert!(table::contains(&cfg.user_positions, k), E_NO_POSITIONS);
        let positions = table::borrow(&cfg.user_positions, k);
        assert!(index < vector::length(positions), E_INDEX_OUT_OF_BOUNDS);
        let pos = vector::borrow(positions, index);
        if (pos.withdrawn) return 0;
        compute_pending_reward(pos.amount, cfg.amplify_apr_bps, pos.last_reward_timestamp, timestamp::now_seconds())
    }
}
