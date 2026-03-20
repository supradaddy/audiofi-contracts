module audiofi::audiofi_stablecoin_autovault {
    use std::bcs;
    use std::signer;
    use std::table;
    use std::vector;
    use std::option::{Self, Option};

    use supra_framework::coin;
    use supra_framework::event;
    use supra_framework::timestamp;

    use audiofi::audiofi_subscriber_graph;


    const E_NOT_ADMIN: u64 = 1;
    const E_NOT_ORACLE: u64 = 2;
    const E_NOT_EXECUTOR: u64 = 3;
    const E_NOT_SYSTEM_OR_ADMIN: u64 = 4;

    const E_PAUSED: u64 = 10;


    const E_BAD_DAY: u64 = 20;
    const E_DAY_ALREADY_SEALED: u64 = 21;
    const E_DAY_NOT_SEALED: u64 = 22;
    const E_SETTLEMENT_NOT_REQUESTED: u64 = 23;
    const E_VERIFICATION_WINDOW_OPEN: u64 = 24;
    const E_SETTLEMENT_ALREADY_EXECUTED: u64 = 25;

    const E_INVALID_AMOUNT: u64 = 60;
    const E_BAD_BPS: u64 = 61;
    const E_LENGTH_MISMATCH: u64 = 62;
    const E_ALREADY_INITIALIZED: u64 = 63;
    const E_ALREADY_REQUESTED: u64 = 64;
    const E_NO_UNITS: u64 = 65;
    const E_DUPLICATE_ARTIST: u64 = 66;


    const DEFAULT_UNVERIFIED_SHARE_BPS: u64 = 7000;
    const DEFAULT_VERIFIED_SHARE_BPS: u64 = 8000;
    const VERIFIED_REDIRECT_BPS: u64 = 1000;

    const DEFAULT_TIER_THRESHOLDS: vector<u64> = vector[1, 5, 20, 50, 100, 250];
    const DEFAULT_TIER_MULTIPLIERS: vector<u64> = vector[10000, 12000, 15000, 20000, 22000, 25000];


    #[event]
    struct ConfigUpdatedEvent has drop, store {
        admin: address,
        system: address,
        oracle: address,
        executor: address,
        registry_admin: address,
        paused: bool,
        daily_budget: Option<u64>,
        daily_payout_bps: u64,
        runway_days: u64,
        verification_window_secs: u64,
        unverified_share_bps: u64,
        verified_share_bps: u64,
        ts: u64,
    }

    #[event]
    struct VaultDepositEvent has drop, store {
        amount: u64,
        vault_balance: u64,
        ts: u64
    }

    #[event]
    struct NewDayStartedEvent has drop, store {
        day_id: u64,
        ts: u64
    }

    #[event]
    struct SettlementRequestedEvent has drop, store {
        day_id: u64,
        verification_unlock_ts: u64,
        ts: u64
    }

    #[event]
    struct DaySealedEvent has drop, store {
        day_id: u64,
        total_weighted_units: u128,
        total_verified_weighted_units: u128,
        total_unverified_weighted_units: u128,
        distributable_pool_amount: u64,
        redirected_pool_amount: u64,
        ts: u64
    }

    #[event]
    struct ArtistDaySubmittedEvent has drop, store {
        day_id: u64,
        artist: address,
        base_units: u64,
        weighted_units: u128,
        is_verified: bool,
        payout_share_bps: u64,
        ts: u64
    }

    #[event]
    struct ArtistPaidEvent has drop, store {
        day_id: u64,
        artist: address,
        direct_payout: u64,
        verified_bonus_payout: u64,
        total_payout: u64,
        ts: u64
    }

    #[event]
    struct ArtistVerifiedUpdatedEvent has drop, store {
        artist: address,
        is_verified: bool,
        ts: u64
    }

    #[event]
    struct ArtistBlockedEvent has drop, store {
        artist: address,
        blocked: bool,
        ts: u64
    }

    #[event]
    struct TierConfigUpdatedEvent has drop, store {
        thresholds: vector<u64>,
        multipliers: vector<u64>,
        ts: u64,
    }

    #[event]
    struct SettlementExecutedEvent has drop, store {
        day_id: u64,
        artists_paid: u64,
        total_paid: u64,
        redirected_pool: u64,
        vault_balance_after: u64,
        ts: u64
    }


    struct ArtistDaySnapshot has store, copy, drop {
        base_units: u64,
        weighted_units: u128,
        is_verified: bool,
        blocked_at_seal: bool,
    }


    struct Config<phantom CoinType> has key {
        admin: address,
        system: address,
        oracle: address,
        executor: address,
        registry_admin: address,

        paused: bool,

        current_day_id: u64,
        day_start_ts: table::Table<u64, u64>,

        daily_budget: Option<u64>,
        daily_payout_bps: u64,
        runway_days: u64,
        verification_window_secs: u64,

        unverified_share_bps: u64,
        verified_share_bps: u64,

        tier_thresholds: vector<u64>,
        tier_multipliers: vector<u64>,

        vault: coin::Coin<CoinType>,

        artist_day_snapshots: table::Table<vector<u8>, ArtistDaySnapshot>,

        day_total_weighted_units: table::Table<u64, u128>,
        day_total_verified_weighted_units: table::Table<u64, u128>,
        day_total_unverified_weighted_units: table::Table<u64, u128>,

        day_pool_amount: table::Table<u64, u64>,
        day_redirected_pool_amount: table::Table<u64, u64>,

        day_sealed: table::Table<u64, bool>,
        settlement_requested: table::Table<u64, bool>,
        day_committed_ts: table::Table<u64, u64>,
        day_distributed: table::Table<u64, bool>,

        artist_is_verified: table::Table<vector<u8>, bool>,
        artist_payout_blocked: table::Table<vector<u8>, bool>,
    }


    fun key_artist(a: address): vector<u8> {
        bcs::to_bytes(&a)
    }

    fun key_day_artist(day: u64, a: address): vector<u8> {
        let k = bcs::to_bytes(&day);
        vector::append(&mut k, bcs::to_bytes(&a));
        k
    }

    fun assert_admin<CoinType>(cfg: &Config<CoinType>, caller: address) {
        assert!(caller == cfg.admin, E_NOT_ADMIN);
    }

    fun assert_oracle<CoinType>(cfg: &Config<CoinType>, caller: address) {
        assert!(caller == cfg.oracle, E_NOT_ORACLE);
    }

    fun assert_executor<CoinType>(cfg: &Config<CoinType>, caller: address) {
        assert!(caller == cfg.executor, E_NOT_EXECUTOR);
    }

    fun assert_admin_or_system<CoinType>(cfg: &Config<CoinType>, caller: address) {
        assert!(caller == cfg.admin || caller == cfg.system, E_NOT_SYSTEM_OR_ADMIN);
    }

    fun assert_not_paused<CoinType>(cfg: &Config<CoinType>) {
        assert!(!cfg.paused, E_PAUSED);
    }

    fun is_true_day(t: &table::Table<u64, bool>, k: u64): bool {
        if (table::contains(t, k)) *table::borrow(t, k) else false
    }

    fun table_upsert_bool(t: &mut table::Table<u64, bool>, k: u64, v: bool) {
        if (table::contains(t, k)) {
            *table::borrow_mut(t, k) = v;
        } else {
            table::add(t, k, v);
        };
    }

    fun table_upsert_u64(t: &mut table::Table<u64, u64>, k: u64, v: u64) {
        if (table::contains(t, k)) {
            *table::borrow_mut(t, k) = v;
        } else {
            table::add(t, k, v);
        };
    }

    fun table_upsert_u128(t: &mut table::Table<u64, u128>, k: u64, v: u128) {
        if (table::contains(t, k)) {
            *table::borrow_mut(t, k) = v;
        } else {
            table::add(t, k, v);
        };
    }

    fun compute_tier_multiplier_bps(
        subscriber_count: u64,
        thresholds: &vector<u64>,
        multipliers: &vector<u64>
    ): u64 {
        let n = vector::length(thresholds);
        let i: u64 = n;
        while (i > 0) {
            i = i - 1;
            if (subscriber_count >= *vector::borrow(thresholds, i)) {
                return *vector::borrow(multipliers, i)
            };
        };
        10000
    }

    fun assert_no_duplicate_address(seen: &vector<address>, addr: address) {
        let n = vector::length(seen);
        let j: u64 = 0;
        while (j < n) {
            assert!(*vector::borrow(seen, j) != addr, E_DUPLICATE_ARTIST);
            j = j + 1;
        };
    }


    public entry fun initialize<CoinType>(
        admin_signer: &signer,
        system: address,
        oracle: address,
        executor: address,
        registry_admin: address,
        daily_payout_bps: u64,
        runway_days: u64,
        verification_window_secs: u64,
    ) {
        let admin = signer::address_of(admin_signer);
        assert!(!exists<Config<CoinType>>(admin), E_ALREADY_INITIALIZED);
        assert!(daily_payout_bps <= 10000, E_BAD_BPS);

        move_to(admin_signer, Config<CoinType> {
            admin,
            system,
            oracle,
            executor,
            registry_admin,

            paused: false,

            current_day_id: 0,
            day_start_ts: table::new<u64, u64>(),

            daily_budget: option::none<u64>(),
            daily_payout_bps,
            runway_days,
            verification_window_secs,

            unverified_share_bps: DEFAULT_UNVERIFIED_SHARE_BPS,
            verified_share_bps: DEFAULT_VERIFIED_SHARE_BPS,

            tier_thresholds: DEFAULT_TIER_THRESHOLDS,
            tier_multipliers: DEFAULT_TIER_MULTIPLIERS,

            vault: coin::zero<CoinType>(),

            artist_day_snapshots: table::new<vector<u8>, ArtistDaySnapshot>(),

            day_total_weighted_units: table::new<u64, u128>(),
            day_total_verified_weighted_units: table::new<u64, u128>(),
            day_total_unverified_weighted_units: table::new<u64, u128>(),

            day_pool_amount: table::new<u64, u64>(),
            day_redirected_pool_amount: table::new<u64, u64>(),

            day_sealed: table::new<u64, bool>(),
            settlement_requested: table::new<u64, bool>(),
            day_committed_ts: table::new<u64, u64>(),
            day_distributed: table::new<u64, bool>(),

            artist_is_verified: table::new<vector<u8>, bool>(),
            artist_payout_blocked: table::new<vector<u8>, bool>(),
        });

        event::emit(ConfigUpdatedEvent {
            admin,
            system,
            oracle,
            executor,
            registry_admin,
            paused: false,
            daily_budget: option::none<u64>(),
            daily_payout_bps,
            runway_days,
            verification_window_secs,
            unverified_share_bps: DEFAULT_UNVERIFIED_SHARE_BPS,
            verified_share_bps: DEFAULT_VERIFIED_SHARE_BPS,
            ts: timestamp::now_seconds(),
        });
    }

    public entry fun set_params<CoinType>(
        admin_signer: &signer,
        admin_addr: address,
        system: address,
        oracle: address,
        executor: address,
        registry_admin: address,
        paused: bool,
        daily_budget: Option<u64>,
        daily_payout_bps: u64,
        runway_days: u64,
        verification_window_secs: u64,
        unverified_share_bps: u64,
        verified_share_bps: u64
    ) acquires Config {
        let admin = signer::address_of(admin_signer);
        let cfg = borrow_global_mut<Config<CoinType>>(admin_addr);

        assert_admin(cfg, admin);
        assert!(daily_payout_bps <= 10000, E_BAD_BPS);
        assert!(unverified_share_bps <= 10000 && verified_share_bps <= 10000, E_BAD_BPS);
        assert!(verified_share_bps >= unverified_share_bps, E_BAD_BPS);
        assert!(verified_share_bps - unverified_share_bps == VERIFIED_REDIRECT_BPS, E_BAD_BPS);

        cfg.system = system;
        cfg.oracle = oracle;
        cfg.executor = executor;
        cfg.registry_admin = registry_admin;
        cfg.paused = paused;
        cfg.daily_budget = daily_budget;
        cfg.daily_payout_bps = daily_payout_bps;
        cfg.runway_days = runway_days;
        cfg.verification_window_secs = verification_window_secs;
        cfg.unverified_share_bps = unverified_share_bps;
        cfg.verified_share_bps = verified_share_bps;

        event::emit(ConfigUpdatedEvent {
            admin: admin_addr,
            system,
            oracle,
            executor,
            registry_admin,
            paused,
            daily_budget,
            daily_payout_bps,
            runway_days,
            verification_window_secs,
            unverified_share_bps,
            verified_share_bps,
            ts: timestamp::now_seconds(),
        });
    }

    public entry fun set_artist_verified<CoinType>(
        caller: &signer,
        admin_addr: address,
        artist: address,
        is_verified: bool
    ) acquires Config {
        let cfg = borrow_global_mut<Config<CoinType>>(admin_addr);
        assert_admin_or_system(cfg, signer::address_of(caller));

        if (table::contains(&cfg.artist_is_verified, key_artist(artist))) {
            *table::borrow_mut(&mut cfg.artist_is_verified, key_artist(artist)) = is_verified;
        } else {
            table::add(&mut cfg.artist_is_verified, key_artist(artist), is_verified);
        };

        event::emit(ArtistVerifiedUpdatedEvent { artist, is_verified, ts: timestamp::now_seconds() });
    }

    public entry fun set_artist_blocked<CoinType>(
        admin_signer: &signer,
        admin_addr: address,
        artist: address,
        blocked: bool
    ) acquires Config {
        let admin = signer::address_of(admin_signer);
        let cfg = borrow_global_mut<Config<CoinType>>(admin_addr);
        assert_admin(cfg, admin);

        if (table::contains(&cfg.artist_payout_blocked, key_artist(artist))) {
            *table::borrow_mut(&mut cfg.artist_payout_blocked, key_artist(artist)) = blocked;
        } else {
            table::add(&mut cfg.artist_payout_blocked, key_artist(artist), blocked);
        };

        event::emit(ArtistBlockedEvent { artist, blocked, ts: timestamp::now_seconds() });
    }

    public entry fun set_tier_config<CoinType>(
        admin_signer: &signer,
        admin_addr: address,
        thresholds: vector<u64>,
        multipliers: vector<u64>
    ) acquires Config {
        let admin = signer::address_of(admin_signer);
        let cfg = borrow_global_mut<Config<CoinType>>(admin_addr);
        assert_admin(cfg, admin);

        let n = vector::length(&thresholds);
        assert!(n == vector::length(&multipliers), E_LENGTH_MISMATCH);
        assert!(n > 0, E_INVALID_AMOUNT);

        let i: u64 = 1;
        while (i < n) {
            assert!(*vector::borrow(&thresholds, i) > *vector::borrow(&thresholds, i - 1), E_BAD_BPS);
            i = i + 1;
        };

        cfg.tier_thresholds = thresholds;
        cfg.tier_multipliers = multipliers;

        event::emit(TierConfigUpdatedEvent {
            thresholds: cfg.tier_thresholds,
            multipliers: cfg.tier_multipliers,
            ts: timestamp::now_seconds(),
        });
    }


    public fun deposit_subscription_revenue<CoinType>(
        system_signer: &signer,
        admin_addr: address,
        payment: coin::Coin<CoinType>
    ) acquires Config {
        let cfg = borrow_global_mut<Config<CoinType>>(admin_addr);
        assert_admin_or_system(cfg, signer::address_of(system_signer));

        let amt = coin::value(&payment);
        assert!(amt > 0, E_INVALID_AMOUNT);

        coin::merge(&mut cfg.vault, payment);

        event::emit(VaultDepositEvent {
            amount: amt,
            vault_balance: coin::value(&cfg.vault),
            ts: timestamp::now_seconds()
        });
    }

    public entry fun deposit_manual<CoinType>(
        admin_signer: &signer,
        admin_addr: address,
        amount: u64
    ) acquires Config {
        let admin = signer::address_of(admin_signer);
        let cfg = borrow_global_mut<Config<CoinType>>(admin_addr);

        assert_admin(cfg, admin);
        assert!(amount > 0, E_INVALID_AMOUNT);

        let c = coin::withdraw<CoinType>(admin_signer, amount);
        coin::merge(&mut cfg.vault, c);

        event::emit(VaultDepositEvent {
            amount,
            vault_balance: coin::value(&cfg.vault),
            ts: timestamp::now_seconds()
        });
    }


    public entry fun start_new_day<CoinType>(
        caller: &signer,
        admin_addr: address
    ) acquires Config {
        let cfg = borrow_global_mut<Config<CoinType>>(admin_addr);

        assert_not_paused(cfg);
        assert_admin_or_system(cfg, signer::address_of(caller));

        cfg.current_day_id = cfg.current_day_id + 1;

        let ts = timestamp::now_seconds();
        table_upsert_u64(&mut cfg.day_start_ts, cfg.current_day_id, ts);

        event::emit(NewDayStartedEvent { day_id: cfg.current_day_id, ts });
    }

    public entry fun submit_artist_day_batch<CoinType>(
        oracle_signer: &signer,
        admin_addr: address,
        day_id: u64,
        artists: vector<address>,
        base_units: vector<u64>
    ) acquires Config {
        let cfg = borrow_global_mut<Config<CoinType>>(admin_addr);

        assert_not_paused(cfg);
        assert_oracle(cfg, signer::address_of(oracle_signer));
        assert!(day_id <= cfg.current_day_id, E_BAD_DAY);
        assert!(vector::length(&artists) == vector::length(&base_units), E_LENGTH_MISMATCH);
        assert!(!is_true_day(&cfg.day_sealed, day_id), E_DAY_ALREADY_SEALED);

        let registry_admin = cfg.registry_admin;
        let u_share = cfg.unverified_share_bps;
        let v_share = cfg.verified_share_bps;

        let total_weighted: u128 = 0;
        let total_verified_weighted: u128 = 0;
        let total_unverified_weighted: u128 = 0;

        let i: u64 = 0;
        let n = vector::length(&artists);
        let ts = timestamp::now_seconds();

        while (i < n) {
            let artist = *vector::borrow(&artists, i);
            let base = *vector::borrow(&base_units, i);

            let (active_count, _, _) = audiofi_subscriber_graph::view_artist_stats(registry_admin, artist);

            let weighted = if (active_count == 0) {
                0u128
            } else {
                let mult_bps = compute_tier_multiplier_bps(
                    active_count,
                    &cfg.tier_thresholds,
                    &cfg.tier_multipliers
                );
                (base as u128) * (mult_bps as u128) / 10000
            };

            let is_verified =
                if (table::contains(&cfg.artist_is_verified, key_artist(artist)))
                    *table::borrow(&cfg.artist_is_verified, key_artist(artist))
                else false;

            let blocked =
                if (table::contains(&cfg.artist_payout_blocked, key_artist(artist)))
                    *table::borrow(&cfg.artist_payout_blocked, key_artist(artist))
                else false;

            assert!(
                !table::contains(&cfg.artist_day_snapshots, key_day_artist(day_id, artist)),
                E_DUPLICATE_ARTIST
            );

            table::add(&mut cfg.artist_day_snapshots, key_day_artist(day_id, artist), ArtistDaySnapshot {
                base_units: base,
                weighted_units: weighted,
                is_verified,
                blocked_at_seal: blocked,
            });

            if (is_verified) {
                total_verified_weighted = total_verified_weighted + weighted;
            } else {
                total_unverified_weighted = total_unverified_weighted + weighted;
            };

            total_weighted = total_weighted + weighted;

            event::emit(ArtistDaySubmittedEvent {
                day_id,
                artist,
                base_units: base,
                weighted_units: weighted,
                is_verified,
                payout_share_bps: if (is_verified) v_share else u_share,
                ts,
            });

            i = i + 1;
        };

        table_upsert_u128(&mut cfg.day_total_weighted_units, day_id, total_weighted);
        table_upsert_u128(&mut cfg.day_total_verified_weighted_units, day_id, total_verified_weighted);
        table_upsert_u128(&mut cfg.day_total_unverified_weighted_units, day_id, total_unverified_weighted);


        let vault_bal = coin::value(&cfg.vault);

        let raw_pool = (((vault_bal as u128) * (cfg.daily_payout_bps as u128) / 10000) as u64);

        let runway_cap = if (cfg.runway_days > 0) {
            vault_bal / cfg.runway_days
        } else {
            raw_pool
        };

        let pool_base = if (runway_cap < raw_pool) runway_cap else raw_pool;

        let pool =
            if (option::is_some(&cfg.daily_budget)) {
                let budget = *option::borrow(&cfg.daily_budget);
                if (budget < pool_base) budget else pool_base
            } else {
                pool_base
            };

        table_upsert_u64(&mut cfg.day_pool_amount, day_id, pool);

        let redirected_pool_amount = if (total_weighted > 0) {
            (((pool as u128) * total_unverified_weighted * (VERIFIED_REDIRECT_BPS as u128)
             / (total_weighted * 10000)) as u64)
        } else {
            0
        };
        table_upsert_u64(&mut cfg.day_redirected_pool_amount, day_id, redirected_pool_amount);

        table_upsert_bool(&mut cfg.day_sealed, day_id, true);

        event::emit(DaySealedEvent {
            day_id,
            total_weighted_units: total_weighted,
            total_verified_weighted_units: total_verified_weighted,
            total_unverified_weighted_units: total_unverified_weighted,
            distributable_pool_amount: pool,
            redirected_pool_amount,
            ts,
        });
    }

    public entry fun request_settlement<CoinType>(
        caller: &signer,
        admin_addr: address,
        day_id: u64
    ) acquires Config {
        let cfg = borrow_global_mut<Config<CoinType>>(admin_addr);

        assert_not_paused(cfg);
        assert_admin_or_system(cfg, signer::address_of(caller));
        assert!(day_id <= cfg.current_day_id, E_BAD_DAY);
        assert!(is_true_day(&cfg.day_sealed, day_id), E_DAY_NOT_SEALED);

        if (table::contains(&cfg.settlement_requested, day_id)) {
            assert!(!*table::borrow(&cfg.settlement_requested, day_id), E_ALREADY_REQUESTED);
        };

        let ts = timestamp::now_seconds();
        let unlock_ts = ts + cfg.verification_window_secs;

        table_upsert_bool(&mut cfg.settlement_requested, day_id, true);
        table_upsert_u64(&mut cfg.day_committed_ts, day_id, ts);

        event::emit(SettlementRequestedEvent {
            day_id,
            verification_unlock_ts: unlock_ts,
            ts
        });
    }

    public entry fun execute_settlement_batch<CoinType>(
        executor_signer: &signer,
        admin_addr: address,
        day_id: u64,
        artists: vector<address>
    ) acquires Config {
        let cfg = borrow_global_mut<Config<CoinType>>(admin_addr);

        assert_not_paused(cfg);
        assert_executor(cfg, signer::address_of(executor_signer));
        assert!(is_true_day(&cfg.day_sealed, day_id), E_DAY_NOT_SEALED);
        assert!(is_true_day(&cfg.settlement_requested, day_id), E_SETTLEMENT_NOT_REQUESTED);
        assert!(!is_true_day(&cfg.day_distributed, day_id), E_SETTLEMENT_ALREADY_EXECUTED);

        let n = vector::length(&artists);
        assert!(n > 0, E_NO_UNITS);

        let committed_ts =
            if (table::contains(&cfg.day_committed_ts, day_id))
                *table::borrow(&cfg.day_committed_ts, day_id)
            else
                0;

        assert!(committed_ts > 0, E_SETTLEMENT_NOT_REQUESTED);
        assert!(
            timestamp::now_seconds() >= committed_ts + cfg.verification_window_secs,
            E_VERIFICATION_WINDOW_OPEN
        );

        let total_weighted =
            if (table::contains(&cfg.day_total_weighted_units, day_id))
                *table::borrow(&cfg.day_total_weighted_units, day_id)
            else
                0;

        assert!(total_weighted > 0, E_NO_UNITS);

        let total_verified_weighted =
            if (table::contains(&cfg.day_total_verified_weighted_units, day_id))
                *table::borrow(&cfg.day_total_verified_weighted_units, day_id)
            else
                0;

        let pool =
            if (table::contains(&cfg.day_pool_amount, day_id))
                *table::borrow(&cfg.day_pool_amount, day_id)
            else
                0;

        let redirected_pool =
            if (table::contains(&cfg.day_redirected_pool_amount, day_id))
                *table::borrow(&cfg.day_redirected_pool_amount, day_id)
            else
                0;


        let seen = vector::empty<address>();
        let direct_payouts = vector::empty<u64>();
        let snap_weighted = vector::empty<u128>();
        let snap_verified = vector::empty<bool>();
        let snap_payable = vector::empty<bool>();

        let i: u64 = 0;
        while (i < n) {
            let artist = *vector::borrow(&artists, i);

            assert_no_duplicate_address(&seen, artist);
            vector::push_back(&mut seen, artist);

            let key = key_day_artist(day_id, artist);
            assert!(table::contains(&cfg.artist_day_snapshots, key), E_BAD_DAY);

            let snap = *table::borrow(&cfg.artist_day_snapshots, key);

            if (!snap.blocked_at_seal && snap.weighted_units > 0) {
                let base_share = (((pool as u128) * snap.weighted_units / total_weighted) as u64);

                let direct = if (snap.is_verified) {
                    (((base_share as u128) * (cfg.verified_share_bps as u128) / 10000) as u64)
                } else {
                    (((base_share as u128) * (cfg.unverified_share_bps as u128) / 10000) as u64)
                };

                vector::push_back(&mut direct_payouts, direct);
                vector::push_back(&mut snap_weighted, snap.weighted_units);
                vector::push_back(&mut snap_verified, snap.is_verified);
                vector::push_back(&mut snap_payable, true);
            } else {
                vector::push_back(&mut direct_payouts, 0);
                vector::push_back(&mut snap_weighted, 0);
                vector::push_back(&mut snap_verified, false);
                vector::push_back(&mut snap_payable, false);
            };

            i = i + 1;
        };


        let artists_paid: u64 = 0;
        let total_paid: u64 = 0;

        i = 0;
        while (i < n) {
            if (*vector::borrow(&snap_payable, i)) {
                let artist = *vector::borrow(&artists, i);
                let direct = *vector::borrow(&direct_payouts, i);
                let is_v = *vector::borrow(&snap_verified, i);

                let verified_bonus = if (is_v && total_verified_weighted > 0 && redirected_pool > 0) {
                    let w = *vector::borrow(&snap_weighted, i);
                    (((redirected_pool as u128) * w / total_verified_weighted) as u64)
                } else {
                    0
                };

                let total_artist_payout = direct + verified_bonus;

                if (total_artist_payout > 0) {
                    let pay = coin::extract(&mut cfg.vault, total_artist_payout);
                    coin::deposit<CoinType>(artist, pay);

                    artists_paid = artists_paid + 1;
                    total_paid = total_paid + total_artist_payout;

                    event::emit(ArtistPaidEvent {
                        day_id,
                        artist,
                        direct_payout: direct,
                        verified_bonus_payout: verified_bonus,
                        total_payout: total_artist_payout,
                        ts: timestamp::now_seconds(),
                    });
                };
            };

            i = i + 1;
        };

        table_upsert_bool(&mut cfg.day_distributed, day_id, true);

        event::emit(SettlementExecutedEvent {
            day_id,
            artists_paid,
            total_paid,
            redirected_pool,
            vault_balance_after: coin::value(&cfg.vault),
            ts: timestamp::now_seconds(),
        });
    }


    #[view]
    public fun view_vault_balance<CoinType>(
        admin_addr: address
    ): u64 acquires Config {
        coin::value(&borrow_global<Config<CoinType>>(admin_addr).vault)
    }

    #[view]
    public fun view_current_day<CoinType>(
        admin_addr: address
    ): u64 acquires Config {
        borrow_global<Config<CoinType>>(admin_addr).current_day_id
    }

    #[view]
    public fun view_day_pool<CoinType>(
        admin_addr: address,
        day_id: u64
    ): u64 acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);
        if (table::contains(&cfg.day_pool_amount, day_id))
            *table::borrow(&cfg.day_pool_amount, day_id)
        else
            0
    }

    #[view]
    public fun view_day_redirected_pool<CoinType>(
        admin_addr: address,
        day_id: u64
    ): u64 acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);
        if (table::contains(&cfg.day_redirected_pool_amount, day_id))
            *table::borrow(&cfg.day_redirected_pool_amount, day_id)
        else
            0
    }

    #[view]
    public fun view_day_total_weighted_units<CoinType>(
        admin_addr: address,
        day_id: u64
    ): u128 acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);
        if (table::contains(&cfg.day_total_weighted_units, day_id))
            *table::borrow(&cfg.day_total_weighted_units, day_id)
        else
            0
    }

    #[view]
    public fun view_day_total_verified_weighted_units<CoinType>(
        admin_addr: address,
        day_id: u64
    ): u128 acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);
        if (table::contains(&cfg.day_total_verified_weighted_units, day_id))
            *table::borrow(&cfg.day_total_verified_weighted_units, day_id)
        else
            0
    }

    #[view]
    public fun view_day_total_unverified_weighted_units<CoinType>(
        admin_addr: address,
        day_id: u64
    ): u128 acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);
        if (table::contains(&cfg.day_total_unverified_weighted_units, day_id))
            *table::borrow(&cfg.day_total_unverified_weighted_units, day_id)
        else
            0
    }

    #[view]
    public fun view_day_sealed<CoinType>(
        admin_addr: address,
        day_id: u64
    ): bool acquires Config {
        is_true_day(&borrow_global<Config<CoinType>>(admin_addr).day_sealed, day_id)
    }

    #[view]
    public fun view_day_distributed<CoinType>(
        admin_addr: address,
        day_id: u64
    ): bool acquires Config {
        is_true_day(&borrow_global<Config<CoinType>>(admin_addr).day_distributed, day_id)
    }

    #[view]
    public fun view_settlement_requested<CoinType>(
        admin_addr: address,
        day_id: u64
    ): bool acquires Config {
        is_true_day(&borrow_global<Config<CoinType>>(admin_addr).settlement_requested, day_id)
    }

    #[view]
    public fun view_settlement_unlock_time<CoinType>(
        admin_addr: address,
        day_id: u64
    ): u64 acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);

        if (!table::contains(&cfg.day_committed_ts, day_id)) return 0;

        let committed = *table::borrow(&cfg.day_committed_ts, day_id);
        committed + cfg.verification_window_secs
    }

    #[view]
    public fun view_artist_units<CoinType>(
        admin_addr: address,
        day_id: u64,
        artist: address
    ): (u64, u128, bool) acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);
        let key = key_day_artist(day_id, artist);

        if (!table::contains(&cfg.artist_day_snapshots, key)) {
            return (0, 0, false)
        };

        let snap = *table::borrow(&cfg.artist_day_snapshots, key);
        (snap.base_units, snap.weighted_units, snap.is_verified)
    }

    #[view]
    public fun view_artist_snapshot_blocked<CoinType>(
        admin_addr: address,
        day_id: u64,
        artist: address
    ): bool acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);
        let key = key_day_artist(day_id, artist);

        if (!table::contains(&cfg.artist_day_snapshots, key)) {
            return false
        };

        let snap = *table::borrow(&cfg.artist_day_snapshots, key);
        snap.blocked_at_seal
    }

    #[view]
    public fun view_artist_verified<CoinType>(
        admin_addr: address,
        artist: address
    ): bool acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);

        if (table::contains(&cfg.artist_is_verified, key_artist(artist)))
            *table::borrow(&cfg.artist_is_verified, key_artist(artist))
        else
            false
    }

    #[view]
    public fun view_artist_blocked<CoinType>(
        admin_addr: address,
        artist: address
    ): bool acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);

        if (table::contains(&cfg.artist_payout_blocked, key_artist(artist)))
            *table::borrow(&cfg.artist_payout_blocked, key_artist(artist))
        else
            false
    }

    #[view]
    public fun view_share_params<CoinType>(
        admin_addr: address
    ): (u64, u64, u64) acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);
        (
            cfg.unverified_share_bps,
            cfg.verified_share_bps,
            VERIFIED_REDIRECT_BPS
        )
    }

    #[view]
    public fun view_artist_tier_multiplier<CoinType>(
        admin_addr: address,
        artist: address
    ): u64 acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);
        let (active_count, _, _) = audiofi_subscriber_graph::view_artist_stats(cfg.registry_admin, artist);
        compute_tier_multiplier_bps(active_count, &cfg.tier_thresholds, &cfg.tier_multipliers)
    }

    #[view]
    public fun view_tier_config_len<CoinType>(
        admin_addr: address
    ): u64 acquires Config {
        vector::length(&borrow_global<Config<CoinType>>(admin_addr).tier_thresholds)
    }

    #[view]
    public fun view_tier_threshold_at<CoinType>(
        admin_addr: address,
        index: u64
    ): u64 acquires Config {
        *vector::borrow(&borrow_global<Config<CoinType>>(admin_addr).tier_thresholds, index)
    }

    #[view]
    public fun view_tier_multiplier_at<CoinType>(
        admin_addr: address,
        index: u64
    ): u64 acquires Config {
        *vector::borrow(&borrow_global<Config<CoinType>>(admin_addr).tier_multipliers, index)
    }

    #[view]
    public fun view_roles<CoinType>(
        admin_addr: address
    ): (address, address, address, address, address) acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);
        (
            cfg.admin,
            cfg.system,
            cfg.oracle,
            cfg.executor,
            cfg.registry_admin
        )
    }

    #[view]
    public fun view_paused<CoinType>(
        admin_addr: address
    ): bool acquires Config {
        borrow_global<Config<CoinType>>(admin_addr).paused
    }

    #[view]
    public fun view_daily_budget<CoinType>(
        admin_addr: address
    ): (bool, u64) acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);
        if (option::is_some(&cfg.daily_budget)) {
            (true, *option::borrow(&cfg.daily_budget))
        } else {
            (false, 0)
        }
    }

    #[view]
    public fun view_daily_payout_bps<CoinType>(
        admin_addr: address
    ): u64 acquires Config {
        borrow_global<Config<CoinType>>(admin_addr).daily_payout_bps
    }

    #[view]
    public fun view_verification_window_secs<CoinType>(
        admin_addr: address
    ): u64 acquires Config {
        borrow_global<Config<CoinType>>(admin_addr).verification_window_secs
    }

    #[view]
    public fun view_runway_days<CoinType>(
        admin_addr: address
    ): u64 acquires Config {
        borrow_global<Config<CoinType>>(admin_addr).runway_days
    }

    #[view]
    public fun view_daily_runway_cap<CoinType>(
        admin_addr: address
    ): u64 acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);
        let vault_bal = coin::value(&cfg.vault);
        if (cfg.runway_days > 0) {
            vault_bal / cfg.runway_days
        } else {
            (((vault_bal as u128) * (cfg.daily_payout_bps as u128) / 10000) as u64)
        }
    }

    #[view]
    public fun preview_artist_payout<CoinType>(
        admin_addr: address,
        day_id: u64,
        artist: address
    ): (u64, u64, u64) acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);
        let key = key_day_artist(day_id, artist);

        if (!table::contains(&cfg.artist_day_snapshots, key)) {
            return (0, 0, 0)
        };

        let snap = *table::borrow(&cfg.artist_day_snapshots, key);

        if (snap.weighted_units == 0 || snap.blocked_at_seal) return (0, 0, 0);

        let total_weighted =
            if (table::contains(&cfg.day_total_weighted_units, day_id))
                *table::borrow(&cfg.day_total_weighted_units, day_id)
            else
                0;

        if (total_weighted == 0) return (0, 0, 0);

        let total_verified_weighted =
            if (table::contains(&cfg.day_total_verified_weighted_units, day_id))
                *table::borrow(&cfg.day_total_verified_weighted_units, day_id)
            else
                0;

        let pool =
            if (table::contains(&cfg.day_pool_amount, day_id))
                *table::borrow(&cfg.day_pool_amount, day_id)
            else
                0;

        let redirected_pool =
            if (table::contains(&cfg.day_redirected_pool_amount, day_id))
                *table::borrow(&cfg.day_redirected_pool_amount, day_id)
            else
                0;

        let base_share = (((pool as u128) * snap.weighted_units / total_weighted) as u64);

        let direct_payout = if (snap.is_verified) {
            (((base_share as u128) * (cfg.verified_share_bps as u128) / 10000) as u64)
        } else {
            (((base_share as u128) * (cfg.unverified_share_bps as u128) / 10000) as u64)
        };

        let verified_bonus =
            if (snap.is_verified && total_verified_weighted > 0 && redirected_pool > 0) {
                (((redirected_pool as u128) * snap.weighted_units / total_verified_weighted) as u64)
            } else {
                0
            };

        (direct_payout, verified_bonus, direct_payout + verified_bonus)
    }
}
