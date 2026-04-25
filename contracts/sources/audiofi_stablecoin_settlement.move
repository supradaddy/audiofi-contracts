module audiofi::audiofi_stablecoin_settlement {
    use std::bcs;
    use std::signer;
    use std::table;
    use std::vector;

    use supra_framework::coin;
    use supra_framework::event;
    use supra_framework::timestamp;

    use audiofi::audiofi_oracle_attest;


    const E_NOT_ADMIN: u64 = 1;
    const E_NOT_ORACLE: u64 = 2;
    const E_NOT_EXECUTOR: u64 = 3;
    const E_NOT_SYSTEM_OR_ADMIN: u64 = 4;

    const E_PAUSED: u64 = 10;

    const E_BAD_DAY: u64 = 20;
    const E_DAY_ALREADY_SEALED: u64 = 21;
    const E_DAY_NOT_SEALED: u64 = 22;
    const E_SETTLEMENT_ALREADY_EXECUTED: u64 = 25;
    const E_DAY_ROOT_NOT_COMMITTED: u64 = 26;
    const E_BATCH_ROOT_MISMATCH: u64 = 27;

    const E_INVALID_AMOUNT: u64 = 60;
    const E_BAD_BPS: u64 = 61;
    const E_LENGTH_MISMATCH: u64 = 62;
    const E_ALREADY_INITIALIZED: u64 = 63;
    const E_NO_UNITS: u64 = 65;
    const E_DUPLICATE_ARTIST: u64 = 66;
    const E_EXCEEDS_MAX_DAILY_PAYOUT: u64 = 67;


    /// Flat share for every artist with at least 1 active Superfan supporter.
    /// The verified flag is preserved on snapshots and events for badge / UX
    /// purposes, but no longer affects the payout share. `VERIFIED_REDIRECT_BPS`
    /// is kept as 0 so the legacy redirect-pool math becomes a no-op without
    /// requiring a deeper code surgery in the seal/payout pipeline.
    const DEFAULT_UNVERIFIED_SHARE_BPS: u64 = 8000;
    const DEFAULT_VERIFIED_SHARE_BPS: u64 = 8000;
    const VERIFIED_REDIRECT_BPS: u64 = 0;

    /// 0.01 USDC with 6 decimals = 10,000 micro-units
    const DEFAULT_MIN_PAYOUT: u64 = 10000;

    const DEFAULT_TIER_THRESHOLDS: vector<u64> = vector[1, 5, 20, 50, 100, 250];
    const DEFAULT_TIER_MULTIPLIERS: vector<u64> = vector[10000, 12000, 15000, 20000, 22000, 25000];


    #[event]
    struct ConfigUpdatedEvent has drop, store {
        admin: address,
        system: address,
        oracle: address,
        executor: address,
        paused: bool,
        daily_payout: u64,
        max_daily_payout: u64,
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
        pending_carried: u64,
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
        artists_below_min: u64,
        total_paid: u64,
        redirected_pool: u64,
        vault_balance_after: u64,
        ts: u64
    }

    /// Emitted after each `execute_settlement_batch` call that doesn't yet
    /// complete the day. Once the day's final batch is processed,
    /// `SettlementExecutedEvent` is emitted instead and `day_distributed` is
    /// set to true.
    #[event]
    struct SettlementBatchExecutedEvent has drop, store {
        day_id: u64,
        artists_paid_in_batch: u64,
        artists_below_min_in_batch: u64,
        total_paid_in_batch: u64,
        settled_so_far: u64,
        total_artists: u64,
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

        paused: bool,

        current_day_id: u64,
        day_start_ts: table::Table<u64, u64>,

        daily_payout: u64,
        max_daily_payout: u64,
        min_payout: u64,

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
        day_distributed: table::Table<u64, bool>,

        /// Number of artists snapshot for a day (set when the day is sealed).
        /// Used to detect when a partial-batch settlement has fully completed.
        day_artist_count: table::Table<u64, u64>,
        /// Number of artists already processed by `execute_settlement_batch`
        /// for a given day. Once it reaches `day_artist_count[day_id]`, the
        /// day is marked distributed.
        day_settled_count: table::Table<u64, u64>,
        /// Per-(day, artist) flag indicating that artist has already been
        /// processed in some prior batch for that day. Prevents double-payment
        /// across or within calls.
        artist_paid_for_day: table::Table<vector<u8>, bool>,

        artist_is_verified: table::Table<vector<u8>, bool>,
        artist_payout_blocked: table::Table<vector<u8>, bool>,

        /// Accumulated sub-threshold payouts per artist (keyed by artist address bytes).
        /// Rolls over until the total meets min_payout, then gets paid out and reset.
        pending_artist_payouts: table::Table<vector<u8>, u64>,
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

    public entry fun initialize<CoinType>(
        admin_signer: &signer,
        system: address,
        oracle: address,
        executor: address,
        daily_payout: u64,
        max_daily_payout: u64,
    ) {
        let admin = signer::address_of(admin_signer);
        assert!(!exists<Config<CoinType>>(admin), E_ALREADY_INITIALIZED);

        move_to(admin_signer, Config<CoinType> {
            admin,
            system,
            oracle,
            executor,

            paused: false,

            current_day_id: 0,
            day_start_ts: table::new<u64, u64>(),

            daily_payout,
            max_daily_payout,
            min_payout: DEFAULT_MIN_PAYOUT,

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
            day_distributed: table::new<u64, bool>(),

            day_artist_count: table::new<u64, u64>(),
            day_settled_count: table::new<u64, u64>(),
            artist_paid_for_day: table::new<vector<u8>, bool>(),

            artist_is_verified: table::new<vector<u8>, bool>(),
            artist_payout_blocked: table::new<vector<u8>, bool>(),

            pending_artist_payouts: table::new<vector<u8>, u64>(),
        });

        event::emit(ConfigUpdatedEvent {
            admin,
            system,
            oracle,
            executor,
            paused: false,
            daily_payout,
            max_daily_payout,
            unverified_share_bps: DEFAULT_UNVERIFIED_SHARE_BPS,
            verified_share_bps: DEFAULT_VERIFIED_SHARE_BPS,
            ts: timestamp::now_seconds(),
        });
    }

    /// Set the daily payout amount distributed to all artists for the day.
    public entry fun set_daily_payout<CoinType>(
        admin_signer: &signer,
        admin_addr: address,
        amount: u64,
    ) acquires Config {
        let cfg = borrow_global_mut<Config<CoinType>>(admin_addr);
        assert_admin(cfg, signer::address_of(admin_signer));
        if (cfg.max_daily_payout > 0) {
            assert!(amount <= cfg.max_daily_payout, E_EXCEEDS_MAX_DAILY_PAYOUT);
        };
        cfg.daily_payout = amount;
    }

    /// Set the maximum USD (in micro-units) that can be paid out to all
    /// artists cumulatively in a single day. 0 means no cap.
    public entry fun set_max_daily_payout<CoinType>(
        admin_signer: &signer,
        admin_addr: address,
        amount: u64,
    ) acquires Config {
        let cfg = borrow_global_mut<Config<CoinType>>(admin_addr);
        assert_admin(cfg, signer::address_of(admin_signer));
        cfg.max_daily_payout = amount;
    }

    /// Set the minimum payout per artist (in micro-units). Artists whose
    /// calculated payout falls below this threshold are skipped, and the
    /// funds remain in the vault for the next day. 0 disables the floor.
    public entry fun set_min_payout<CoinType>(
        admin_signer: &signer,
        admin_addr: address,
        amount: u64,
    ) acquires Config {
        let cfg = borrow_global_mut<Config<CoinType>>(admin_addr);
        assert_admin(cfg, signer::address_of(admin_signer));
        cfg.min_payout = amount;
    }

    public entry fun set_share_bps<CoinType>(
        admin_signer: &signer,
        admin_addr: address,
        unverified_share_bps: u64,
        verified_share_bps: u64,
    ) acquires Config {
        let cfg = borrow_global_mut<Config<CoinType>>(admin_addr);
        assert_admin(cfg, signer::address_of(admin_signer));
        assert!(unverified_share_bps <= 10000 && verified_share_bps <= 10000, E_BAD_BPS);
        assert!(verified_share_bps >= unverified_share_bps, E_BAD_BPS);
        assert!(verified_share_bps - unverified_share_bps == VERIFIED_REDIRECT_BPS, E_BAD_BPS);
        cfg.unverified_share_bps = unverified_share_bps;
        cfg.verified_share_bps = verified_share_bps;
    }

    public entry fun set_paused<CoinType>(
        admin_signer: &signer,
        admin_addr: address,
        paused: bool,
    ) acquires Config {
        let cfg = borrow_global_mut<Config<CoinType>>(admin_addr);
        assert_admin(cfg, signer::address_of(admin_signer));
        cfg.paused = paused;
    }

    public entry fun set_system<CoinType>(
        admin_signer: &signer,
        admin_addr: address,
        system: address,
    ) acquires Config {
        let cfg = borrow_global_mut<Config<CoinType>>(admin_addr);
        assert_admin(cfg, signer::address_of(admin_signer));
        cfg.system = system;
    }

    public entry fun set_oracle<CoinType>(
        admin_signer: &signer,
        admin_addr: address,
        oracle: address,
    ) acquires Config {
        let cfg = borrow_global_mut<Config<CoinType>>(admin_addr);
        assert_admin(cfg, signer::address_of(admin_signer));
        cfg.oracle = oracle;
    }

    public entry fun set_executor<CoinType>(
        admin_signer: &signer,
        admin_addr: address,
        executor: address,
    ) acquires Config {
        let cfg = borrow_global_mut<Config<CoinType>>(admin_addr);
        assert_admin(cfg, signer::address_of(admin_signer));
        cfg.executor = executor;
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

    /// Submit the daily batch of (artist, base_units, active_subscriber_count)
    /// for a settlement day. `active_counts` contains the off-chain-attested
    /// number of active superfan supporters for each artist on `day_id`, used
    /// purely for the tier multiplier. The batch is verified against the
    /// oracle's pre-committed `batch_root`; callers MUST hash all three
    /// vectors into the root they commit, otherwise this call will fail.
    public entry fun submit_artist_day_batch<CoinType>(
        oracle_signer: &signer,
        admin_addr: address,
        day_id: u64,
        artists: vector<address>,
        base_units: vector<u64>,
        active_counts: vector<u64>,
        batch_root: vector<u8>
    ) acquires Config {
        let cfg = borrow_global_mut<Config<CoinType>>(admin_addr);

        assert_not_paused(cfg);
        assert_oracle(cfg, signer::address_of(oracle_signer));
        assert!(day_id <= cfg.current_day_id, E_BAD_DAY);
        assert!(vector::length(&artists) == vector::length(&base_units), E_LENGTH_MISMATCH);
        assert!(vector::length(&artists) == vector::length(&active_counts), E_LENGTH_MISMATCH);
        assert!(!is_true_day(&cfg.day_sealed, day_id), E_DAY_ALREADY_SEALED);
        assert!(
            audiofi_oracle_attest::view_day_attestation_committed(admin_addr, day_id),
            E_DAY_ROOT_NOT_COMMITTED
        );
        assert!(
            audiofi_oracle_attest::view_artist_batch_root_matches(admin_addr, day_id, batch_root),
            E_BATCH_ROOT_MISMATCH
        );

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
            let active_count = *vector::borrow(&active_counts, i);

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
        let raw_pool = cfg.daily_payout;
        let capped = if (cfg.max_daily_payout > 0 && raw_pool > cfg.max_daily_payout) {
            cfg.max_daily_payout
        } else {
            raw_pool
        };
        let pool = if (capped > vault_bal) { vault_bal } else { capped };

        table_upsert_u64(&mut cfg.day_pool_amount, day_id, pool);

        let redirected_pool_amount = if (total_weighted > 0) {
            (((pool as u128) * total_unverified_weighted * (VERIFIED_REDIRECT_BPS as u128)
             / (total_weighted * 10000)) as u64)
        } else {
            0
        };
        table_upsert_u64(&mut cfg.day_redirected_pool_amount, day_id, redirected_pool_amount);

        table_upsert_bool(&mut cfg.day_sealed, day_id, true);
        // Record the total number of artists snapshot for this day so that
        // `execute_settlement_batch` can detect when all batches have been
        // processed and only then mark the day as fully distributed.
        table_upsert_u64(&mut cfg.day_artist_count, day_id, n);

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

    /// Process a batch of artists for `day_id`, paying out their share of the
    /// daily pool (carrying forward any sub-`min_payout` accruals). Settlement
    /// is idempotent per (day, artist): re-submitting an artist that's already
    /// been paid for the day is a no-op. Once every artist snapshot for the day
    /// has been processed (across one or many batches), the day is marked
    /// distributed and `SettlementExecutedEvent` is emitted.
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
        assert!(!is_true_day(&cfg.day_distributed, day_id), E_SETTLEMENT_ALREADY_EXECUTED);
        assert!(
            audiofi_oracle_attest::view_day_attestation_committed(admin_addr, day_id),
            E_DAY_ROOT_NOT_COMMITTED
        );
        execute_settlement_internal(cfg, day_id, artists);
    }

    fun execute_settlement_internal<CoinType>(
        cfg: &mut Config<CoinType>,
        day_id: u64,
        artists: vector<address>
    ) {
        let n = vector::length(&artists);
        assert!(n > 0, E_NO_UNITS);

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

        let min_pay = cfg.min_payout;

        let artists_paid: u64 = 0;
        let artists_below_min: u64 = 0;
        let total_paid: u64 = 0;
        let processed_in_batch: u64 = 0;

        let i: u64 = 0;
        while (i < n) {
            let artist = *vector::borrow(&artists, i);
            let kda = key_day_artist(day_id, artist);

            // Idempotent: skip artists already processed for this day, whether
            // in a prior batch or earlier in this same call.
            let already_paid =
                if (table::contains(&cfg.artist_paid_for_day, kda))
                    *table::borrow(&cfg.artist_paid_for_day, kda)
                else
                    false;

            if (!already_paid) {
                assert!(table::contains(&cfg.artist_day_snapshots, kda), E_BAD_DAY);
                let snap = *table::borrow(&cfg.artist_day_snapshots, kda);

                if (!snap.blocked_at_seal && snap.weighted_units > 0) {
                    let base_share = (((pool as u128) * snap.weighted_units / total_weighted) as u64);

                    let direct = if (snap.is_verified) {
                        (((base_share as u128) * (cfg.verified_share_bps as u128) / 10000) as u64)
                    } else {
                        (((base_share as u128) * (cfg.unverified_share_bps as u128) / 10000) as u64)
                    };

                    let verified_bonus = if (snap.is_verified && total_verified_weighted > 0 && redirected_pool > 0) {
                        (((redirected_pool as u128) * snap.weighted_units / total_verified_weighted) as u64)
                    } else {
                        0
                    };

                    let today_earned = direct + verified_bonus;

                    if (today_earned > 0) {
                        let ak = key_artist(artist);
                        let pending = if (table::contains(&cfg.pending_artist_payouts, ak))
                            *table::borrow(&cfg.pending_artist_payouts, ak)
                        else
                            0;

                        let combined = pending + today_earned;

                        if (combined >= min_pay) {
                            let pay = coin::extract(&mut cfg.vault, combined);
                            coin::deposit<CoinType>(artist, pay);

                            artists_paid = artists_paid + 1;
                            total_paid = total_paid + combined;

                            if (table::contains(&cfg.pending_artist_payouts, ak)) {
                                *table::borrow_mut(&mut cfg.pending_artist_payouts, ak) = 0;
                            };

                            event::emit(ArtistPaidEvent {
                                day_id,
                                artist,
                                direct_payout: direct,
                                verified_bonus_payout: verified_bonus,
                                pending_carried: pending,
                                total_payout: combined,
                                ts: timestamp::now_seconds(),
                            });
                        } else {
                            if (table::contains(&cfg.pending_artist_payouts, ak)) {
                                *table::borrow_mut(&mut cfg.pending_artist_payouts, ak) = combined;
                            } else {
                                table::add(&mut cfg.pending_artist_payouts, ak, combined);
                            };
                            artists_below_min = artists_below_min + 1;
                        };
                    };
                };

                table::add(&mut cfg.artist_paid_for_day, kda, true);
                processed_in_batch = processed_in_batch + 1;
            };

            i = i + 1;
        };

        // Accumulate progress across batches; only mark the day as fully
        // distributed once every artist in the snapshot has been processed.
        let prior = if (table::contains(&cfg.day_settled_count, day_id))
            *table::borrow(&cfg.day_settled_count, day_id)
        else
            0;
        let new_settled = prior + processed_in_batch;
        table_upsert_u64(&mut cfg.day_settled_count, day_id, new_settled);

        let expected = if (table::contains(&cfg.day_artist_count, day_id))
            *table::borrow(&cfg.day_artist_count, day_id)
        else
            0;

        if (expected > 0 && new_settled >= expected) {
            table_upsert_bool(&mut cfg.day_distributed, day_id, true);
            event::emit(SettlementExecutedEvent {
                day_id,
                artists_paid,
                artists_below_min,
                total_paid,
                redirected_pool,
                vault_balance_after: coin::value(&cfg.vault),
                ts: timestamp::now_seconds(),
            });
        } else {
            event::emit(SettlementBatchExecutedEvent {
                day_id,
                artists_paid_in_batch: artists_paid,
                artists_below_min_in_batch: artists_below_min,
                total_paid_in_batch: total_paid,
                settled_so_far: new_settled,
                total_artists: expected,
                ts: timestamp::now_seconds(),
            });
        };
    }


    #[view]
    public fun view_vault_balance<CoinType>(admin_addr: address): u64 acquires Config {
        coin::value(&borrow_global<Config<CoinType>>(admin_addr).vault)
    }

    #[view]
    public fun view_current_day<CoinType>(admin_addr: address): u64 acquires Config {
        borrow_global<Config<CoinType>>(admin_addr).current_day_id
    }

    #[view]
    public fun view_daily_payout<CoinType>(admin_addr: address): u64 acquires Config {
        borrow_global<Config<CoinType>>(admin_addr).daily_payout
    }

    #[view]
    public fun view_max_daily_payout<CoinType>(admin_addr: address): u64 acquires Config {
        borrow_global<Config<CoinType>>(admin_addr).max_daily_payout
    }

    #[view]
    public fun view_day_pool<CoinType>(admin_addr: address, day_id: u64): u64 acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);
        if (table::contains(&cfg.day_pool_amount, day_id))
            *table::borrow(&cfg.day_pool_amount, day_id)
        else
            0
    }

    #[view]
    public fun view_day_redirected_pool<CoinType>(admin_addr: address, day_id: u64): u64 acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);
        if (table::contains(&cfg.day_redirected_pool_amount, day_id))
            *table::borrow(&cfg.day_redirected_pool_amount, day_id)
        else
            0
    }

    #[view]
    public fun view_day_total_weighted_units<CoinType>(admin_addr: address, day_id: u64): u128 acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);
        if (table::contains(&cfg.day_total_weighted_units, day_id))
            *table::borrow(&cfg.day_total_weighted_units, day_id)
        else
            0
    }

    #[view]
    public fun view_day_total_verified_weighted_units<CoinType>(admin_addr: address, day_id: u64): u128 acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);
        if (table::contains(&cfg.day_total_verified_weighted_units, day_id))
            *table::borrow(&cfg.day_total_verified_weighted_units, day_id)
        else
            0
    }

    #[view]
    public fun view_day_total_unverified_weighted_units<CoinType>(admin_addr: address, day_id: u64): u128 acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);
        if (table::contains(&cfg.day_total_unverified_weighted_units, day_id))
            *table::borrow(&cfg.day_total_unverified_weighted_units, day_id)
        else
            0
    }

    #[view]
    public fun view_day_sealed<CoinType>(admin_addr: address, day_id: u64): bool acquires Config {
        is_true_day(&borrow_global<Config<CoinType>>(admin_addr).day_sealed, day_id)
    }

    #[view]
    public fun view_day_distributed<CoinType>(admin_addr: address, day_id: u64): bool acquires Config {
        is_true_day(&borrow_global<Config<CoinType>>(admin_addr).day_distributed, day_id)
    }

    #[view]
    public fun view_day_artist_count<CoinType>(admin_addr: address, day_id: u64): u64 acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);
        if (table::contains(&cfg.day_artist_count, day_id))
            *table::borrow(&cfg.day_artist_count, day_id)
        else
            0
    }

    #[view]
    public fun view_day_settled_count<CoinType>(admin_addr: address, day_id: u64): u64 acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);
        if (table::contains(&cfg.day_settled_count, day_id))
            *table::borrow(&cfg.day_settled_count, day_id)
        else
            0
    }

    #[view]
    public fun view_artist_paid_for_day<CoinType>(admin_addr: address, day_id: u64, artist: address): bool acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);
        let kda = key_day_artist(day_id, artist);
        if (table::contains(&cfg.artist_paid_for_day, kda))
            *table::borrow(&cfg.artist_paid_for_day, kda)
        else
            false
    }

    #[view]
    public fun view_artist_units<CoinType>(admin_addr: address, day_id: u64, artist: address): (u64, u128, bool) acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);
        let key = key_day_artist(day_id, artist);
        if (!table::contains(&cfg.artist_day_snapshots, key)) {
            return (0, 0, false)
        };
        let snap = *table::borrow(&cfg.artist_day_snapshots, key);
        (snap.base_units, snap.weighted_units, snap.is_verified)
    }

    #[view]
    public fun view_artist_snapshot_blocked<CoinType>(admin_addr: address, day_id: u64, artist: address): bool acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);
        let key = key_day_artist(day_id, artist);
        if (!table::contains(&cfg.artist_day_snapshots, key)) {
            return false
        };
        let snap = *table::borrow(&cfg.artist_day_snapshots, key);
        snap.blocked_at_seal
    }

    #[view]
    public fun view_artist_verified<CoinType>(admin_addr: address, artist: address): bool acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);
        if (table::contains(&cfg.artist_is_verified, key_artist(artist)))
            *table::borrow(&cfg.artist_is_verified, key_artist(artist))
        else
            false
    }

    #[view]
    public fun view_artist_blocked<CoinType>(admin_addr: address, artist: address): bool acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);
        if (table::contains(&cfg.artist_payout_blocked, key_artist(artist)))
            *table::borrow(&cfg.artist_payout_blocked, key_artist(artist))
        else
            false
    }

    #[view]
    public fun view_share_params<CoinType>(admin_addr: address): (u64, u64, u64) acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);
        (cfg.unverified_share_bps, cfg.verified_share_bps, VERIFIED_REDIRECT_BPS)
    }

    /// Tier multiplier (in bps) for a given subscriber count. Pure helper:
    /// the off-chain oracle is the source of truth for actual subscriber
    /// counts, fed into `submit_artist_day_batch` per day.
    #[view]
    public fun view_tier_multiplier_for_count<CoinType>(admin_addr: address, active_count: u64): u64 acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);
        compute_tier_multiplier_bps(active_count, &cfg.tier_thresholds, &cfg.tier_multipliers)
    }

    #[view]
    public fun view_tier_config_len<CoinType>(admin_addr: address): u64 acquires Config {
        vector::length(&borrow_global<Config<CoinType>>(admin_addr).tier_thresholds)
    }

    #[view]
    public fun view_tier_threshold_at<CoinType>(admin_addr: address, index: u64): u64 acquires Config {
        *vector::borrow(&borrow_global<Config<CoinType>>(admin_addr).tier_thresholds, index)
    }

    #[view]
    public fun view_tier_multiplier_at<CoinType>(admin_addr: address, index: u64): u64 acquires Config {
        *vector::borrow(&borrow_global<Config<CoinType>>(admin_addr).tier_multipliers, index)
    }

    #[view]
    public fun view_roles<CoinType>(admin_addr: address): (address, address, address, address) acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);
        (cfg.admin, cfg.system, cfg.oracle, cfg.executor)
    }

    #[view]
    public fun view_paused<CoinType>(admin_addr: address): bool acquires Config {
        borrow_global<Config<CoinType>>(admin_addr).paused
    }

    #[view]
    public fun view_min_payout<CoinType>(admin_addr: address): u64 acquires Config {
        borrow_global<Config<CoinType>>(admin_addr).min_payout
    }

    #[view]
    public fun view_artist_pending_payout<CoinType>(admin_addr: address, artist: address): u64 acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);
        let ak = key_artist(artist);
        if (table::contains(&cfg.pending_artist_payouts, ak))
            *table::borrow(&cfg.pending_artist_payouts, ak)
        else
            0
    }

    /// Returns (direct_payout, verified_bonus, pending_carried, total_combined).
    /// total_combined includes any pending amount from prior days.
    #[view]
    public fun preview_artist_payout<CoinType>(admin_addr: address, day_id: u64, artist: address): (u64, u64, u64, u64) acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);
        let key = key_day_artist(day_id, artist);

        if (!table::contains(&cfg.artist_day_snapshots, key)) {
            return (0, 0, 0, 0)
        };

        let snap = *table::borrow(&cfg.artist_day_snapshots, key);
        if (snap.weighted_units == 0 || snap.blocked_at_seal) return (0, 0, 0, 0);

        let total_weighted =
            if (table::contains(&cfg.day_total_weighted_units, day_id))
                *table::borrow(&cfg.day_total_weighted_units, day_id)
            else 0;

        if (total_weighted == 0) return (0, 0, 0, 0);

        let total_verified_weighted =
            if (table::contains(&cfg.day_total_verified_weighted_units, day_id))
                *table::borrow(&cfg.day_total_verified_weighted_units, day_id)
            else 0;

        let pool =
            if (table::contains(&cfg.day_pool_amount, day_id))
                *table::borrow(&cfg.day_pool_amount, day_id)
            else 0;

        let redirected_pool =
            if (table::contains(&cfg.day_redirected_pool_amount, day_id))
                *table::borrow(&cfg.day_redirected_pool_amount, day_id)
            else 0;

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

        let ak = key_artist(artist);
        let pending = if (table::contains(&cfg.pending_artist_payouts, ak))
            *table::borrow(&cfg.pending_artist_payouts, ak)
        else 0;

        (direct_payout, verified_bonus, pending, direct_payout + verified_bonus + pending)
    }
}
