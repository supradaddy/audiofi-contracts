module audiofi::audiofi_aufi_rewards {

    use std::bcs;
    use std::signer;
    use std::table;
    use std::vector;

    use supra_framework::coin;
    use supra_framework::event;
    use supra_framework::timestamp;

    use audiofi::audiofi_subscriber_graph;


    const BPS_DENOM: u64 = 10000;
    const SECONDS_PER_YEAR: u64 = 365 * 24 * 60 * 60;

    const DEFAULT_ANNUAL_EMISSION_BPS: u64 = 1800;
    const DEFAULT_SUBSCRIBER_POOL_BPS: u64 = 6000;
    const DEFAULT_CURATOR_POOL_BPS: u64 = 2000;
    const DEFAULT_AMPLIFY_POOL_BPS: u64 = 2000;
    const DEFAULT_MAX_SHARE_BPS: u64 = 100;

    const DEFAULT_EPOCH_SECS: u64 = 30 * 24 * 60 * 60;


    const E_NOT_ADMIN: u64 = 1;
    const E_NOT_ORACLE: u64 = 2;
    const E_NOT_SYSTEM_OR_ADMIN: u64 = 3;
    const E_PAUSED: u64 = 10;
    const E_BAD_DAY: u64 = 20;
    const E_DAY_NOT_SEALED: u64 = 21;
    const E_DAY_ALREADY_SEALED: u64 = 22;
    const E_BAD_POOL_SPLIT: u64 = 23;
    const E_BAD_PARAMS: u64 = 24;
    const E_DUPLICATE_ADDRESS: u64 = 25;
    const E_NOTHING_TO_CLAIM: u64 = 50;
    const E_EPOCH_NOT_ELAPSED: u64 = 53;
    const E_NO_AMPLIFY_PENDING: u64 = 54;
    const E_ALREADY_INITIALIZED: u64 = 1000;


    #[event]
    struct ConfigUpdatedEvent has drop, store {
        admin: address,
        system: address,
        oracle: address,
        registry_admin: address,
        paused: bool,
        ts: u64,
    }

    #[event]
    struct VaultFundedEvent has drop, store { amount: u64, vault_balance: u64, ts: u64 }

    #[event]
    struct EmissionEvent has drop, store {
        day_id: u64,
        emitted: u64,
        subscriber_pool: u64,
        curator_pool: u64,
        amplify_pool: u64,
        ts: u64,
    }

    #[event]
    struct SubscriberDaySubmittedEvent has drop, store { day_id: u64, user: address, base_units: u64, effective_units: u128, ts: u64 }
    #[event]
    struct CuratorDaySubmittedEvent has drop, store { day_id: u64, curator: address, base_units: u64, effective_units: u128, ts: u64 }
    #[event]
    struct AmplifyDaySubmittedEvent has drop, store { day_id: u64, staker: address, base_units: u64, effective_units: u128, ts: u64 }
    #[event]
    struct DaySealedEvent has drop, store {
        day_id: u64,
        total_subscriber_eff: u128,
        total_curator_eff: u128,
        total_amplify_eff: u128,
        subscriber_pool: u64,
        curator_pool: u64,
        amplify_pool: u64,
        ts: u64,
    }

    #[event]
    struct AccruedSubscriberEvent has drop, store { day_id: u64, user: address, accrued: u64, total_pending: u64, ts: u64 }
    #[event]
    struct AccruedCuratorEvent has drop, store { day_id: u64, curator: address, accrued: u64, total_pending: u64, ts: u64 }
    #[event]
    struct AccruedAmplifyEvent has drop, store { day_id: u64, staker: address, accrued: u64, total_pending: u64, ts: u64 }

    #[event]
    struct RewardsClaimedEvent has drop, store { user: address, claimed: u64, ts: u64 }

    // AmplifyRewardReductionEvent removed — no early exit penalties in the fixed APR model


    struct Config<phantom AufiCoinType, phantom SubCoinType> has key {
        admin: address,
        system: address,
        oracle: address,
        registry_admin: address,
        paused: bool,

        current_day_id: u64,

        annual_emission_bps: u64,
        subscriber_pool_bps: u64,
        curator_pool_bps: u64,
        amplify_pool_bps: u64,
        max_share_bps: u64,
        last_emission_ts: u64,

        epoch_secs: u64,

        vault: coin::Coin<AufiCoinType>,

        subscriber_effective: table::Table<vector<u8>, u128>,
        subscriber_total: table::Table<u64, u128>,

        curator_effective: table::Table<vector<u8>, u128>,
        curator_total: table::Table<u64, u128>,

        amplify_effective: table::Table<vector<u8>, u128>,
        amplify_total: table::Table<u64, u128>,

        subscriber_pool: table::Table<u64, u64>,
        curator_pool: table::Table<u64, u64>,
        amplify_pool: table::Table<u64, u64>,

        day_sealed: table::Table<u64, bool>,

        claimed_subscriber: table::Table<vector<u8>, bool>,
        claimed_curator: table::Table<vector<u8>, bool>,
        claimed_amplify: table::Table<vector<u8>, bool>,

        pending_rewards: table::Table<vector<u8>, u64>,
        pending_amplify_rewards: table::Table<vector<u8>, u64>,
        epoch_start_ts: table::Table<vector<u8>, u64>,
    }


    fun key_addr(a: address): vector<u8> { bcs::to_bytes(&a) }

    fun key_day_user(day: u64, a: address): vector<u8> {
        let k = bcs::to_bytes(&day);
        vector::append(&mut k, bcs::to_bytes(&a));
        k
    }


    fun assert_admin<A, S>(cfg: &Config<A, S>, caller: address) { assert!(caller == cfg.admin, E_NOT_ADMIN); }
    fun assert_oracle<A, S>(cfg: &Config<A, S>, caller: address) { assert!(caller == cfg.oracle, E_NOT_ORACLE); }
    fun assert_admin_or_system<A, S>(cfg: &Config<A, S>, caller: address) { assert!(caller == cfg.admin || caller == cfg.system, E_NOT_SYSTEM_OR_ADMIN); }
    fun assert_not_paused<A, S>(cfg: &Config<A, S>) { assert!(!cfg.paused, E_PAUSED); }

    fun is_true_day(t: &table::Table<u64, bool>, k: u64): bool {
        if (table::contains(t, k)) *table::borrow(t, k) else false
    }


    fun table_upsert_vec<V: drop + store>(t: &mut table::Table<vector<u8>, V>, k: vector<u8>, v: V) {
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

    fun table_upsert_u64(t: &mut table::Table<u64, u64>, k: u64, v: u64) {
        if (table::contains(t, k)) {
            *table::borrow_mut(t, k) = v;
        } else {
            table::add(t, k, v);
        };
    }

    fun table_upsert_bool(t: &mut table::Table<u64, bool>, k: u64, v: bool) {
        if (table::contains(t, k)) {
            *table::borrow_mut(t, k) = v;
        } else {
            table::add(t, k, v);
        };
    }

    fun get_pending(t: &table::Table<vector<u8>, u64>, k: &vector<u8>): u64 {
        if (table::contains(t, *k)) *table::borrow(t, *k) else 0
    }

    fun get_epoch_start(t: &table::Table<vector<u8>, u64>, k: &vector<u8>): u64 {
        if (table::contains(t, *k)) *table::borrow(t, *k) else 0
    }


    public entry fun initialize<AufiCoinType, SubCoinType>(
        admin_signer: &signer,
        system: address,
        oracle: address,
        registry_admin: address,
    ) {
        let admin = signer::address_of(admin_signer);
        assert!(!exists<Config<AufiCoinType, SubCoinType>>(admin), E_ALREADY_INITIALIZED);
        assert!(
            DEFAULT_SUBSCRIBER_POOL_BPS + DEFAULT_CURATOR_POOL_BPS + DEFAULT_AMPLIFY_POOL_BPS == BPS_DENOM,
            E_BAD_POOL_SPLIT
        );

        move_to(admin_signer, Config<AufiCoinType, SubCoinType> {
            admin,
            system,
            oracle,
            registry_admin,
            paused: false,
            current_day_id: 0,

            annual_emission_bps: DEFAULT_ANNUAL_EMISSION_BPS,
            subscriber_pool_bps: DEFAULT_SUBSCRIBER_POOL_BPS,
            curator_pool_bps: DEFAULT_CURATOR_POOL_BPS,
            amplify_pool_bps: DEFAULT_AMPLIFY_POOL_BPS,
            max_share_bps: DEFAULT_MAX_SHARE_BPS,
            last_emission_ts: timestamp::now_seconds(),

            epoch_secs: DEFAULT_EPOCH_SECS,

            vault: coin::zero<AufiCoinType>(),

            subscriber_effective: table::new(),
            subscriber_total: table::new(),

            curator_effective: table::new(),
            curator_total: table::new(),

            amplify_effective: table::new(),
            amplify_total: table::new(),

            subscriber_pool: table::new(),
            curator_pool: table::new(),
            amplify_pool: table::new(),

            day_sealed: table::new(),
            claimed_subscriber: table::new(),
            claimed_curator: table::new(),
            claimed_amplify: table::new(),

            pending_rewards: table::new(),
            pending_amplify_rewards: table::new(),
            epoch_start_ts: table::new(),
        });

        event::emit(ConfigUpdatedEvent { admin, system, oracle, registry_admin, paused: false, ts: timestamp::now_seconds() });
    }


    public entry fun set_params<AufiCoinType, SubCoinType>(
        admin_signer: &signer,
        admin_addr: address,
        system: address,
        oracle: address,
        registry_admin: address,
        paused: bool,
        annual_emission_bps: u64,
        subscriber_pool_bps: u64,
        curator_pool_bps: u64,
        amplify_pool_bps: u64,
        max_share_bps: u64,
        epoch_secs: u64,
    ) acquires Config {
        let admin = signer::address_of(admin_signer);
        let cfg = borrow_global_mut<Config<AufiCoinType, SubCoinType>>(admin_addr);
        assert_admin(cfg, admin);
        assert!(subscriber_pool_bps + curator_pool_bps + amplify_pool_bps == BPS_DENOM, E_BAD_POOL_SPLIT);
        assert!(max_share_bps <= BPS_DENOM, E_BAD_PARAMS);
        assert!(annual_emission_bps <= BPS_DENOM, E_BAD_PARAMS);
        assert!(epoch_secs >= 7 * 24 * 60 * 60, E_BAD_PARAMS);

        cfg.system = system;
        cfg.oracle = oracle;
        cfg.registry_admin = registry_admin;
        cfg.paused = paused;
        cfg.annual_emission_bps = annual_emission_bps;
        cfg.subscriber_pool_bps = subscriber_pool_bps;
        cfg.curator_pool_bps = curator_pool_bps;
        cfg.amplify_pool_bps = amplify_pool_bps;
        cfg.max_share_bps = max_share_bps;
        cfg.epoch_secs = epoch_secs;

        event::emit(ConfigUpdatedEvent { admin: admin_addr, system, oracle, registry_admin, paused, ts: timestamp::now_seconds() });
    }

    public entry fun fund_vault<AufiCoinType, SubCoinType>(
        admin_signer: &signer,
        admin_addr: address,
        amount: u64
    ) acquires Config {
        let admin = signer::address_of(admin_signer);
        let cfg = borrow_global_mut<Config<AufiCoinType, SubCoinType>>(admin_addr);
        assert_admin(cfg, admin);

        let c = coin::withdraw<AufiCoinType>(admin_signer, amount);
        coin::merge(&mut cfg.vault, c);

        event::emit(VaultFundedEvent { amount, vault_balance: coin::value(&cfg.vault), ts: timestamp::now_seconds() });
    }


    fun emit_for_day<AufiCoinType, SubCoinType>(cfg: &mut Config<AufiCoinType, SubCoinType>) {
        let now = timestamp::now_seconds();
        let dt = now - cfg.last_emission_ts;
        cfg.last_emission_ts = now;

        let vault_balance = coin::value(&cfg.vault);
        let emitted = (
            (vault_balance as u128)
            * (cfg.annual_emission_bps as u128)
            * (dt as u128)
        ) / ((BPS_DENOM as u128) * (SECONDS_PER_YEAR as u128));

        let emitted_u64 = (emitted as u64);
        if (emitted_u64 == 0) return;

        let subscriber_pool_amt = (emitted_u64 * cfg.subscriber_pool_bps) / BPS_DENOM;
        let curator_pool_amt = (emitted_u64 * cfg.curator_pool_bps) / BPS_DENOM;
        let amplify_pool_amt = (emitted_u64 * cfg.amplify_pool_bps) / BPS_DENOM;

        table_upsert_u64(&mut cfg.subscriber_pool, cfg.current_day_id, subscriber_pool_amt);
        table_upsert_u64(&mut cfg.curator_pool, cfg.current_day_id, curator_pool_amt);
        table_upsert_u64(&mut cfg.amplify_pool, cfg.current_day_id, amplify_pool_amt);

        event::emit(EmissionEvent {
            day_id: cfg.current_day_id,
            emitted: emitted_u64,
            subscriber_pool: subscriber_pool_amt,
            curator_pool: curator_pool_amt,
            amplify_pool: amplify_pool_amt,
            ts: now,
        });
    }

    public entry fun start_new_day<AufiCoinType, SubCoinType>(
        caller: &signer,
        admin_addr: address
    ) acquires Config {
        let cfg = borrow_global_mut<Config<AufiCoinType, SubCoinType>>(admin_addr);
        assert_not_paused(cfg);
        assert_admin_or_system(cfg, signer::address_of(caller));

        cfg.current_day_id = cfg.current_day_id + 1;
        emit_for_day(cfg);
    }


    public entry fun submit_day_batch<AufiCoinType, SubCoinType>(
        oracle_signer: &signer,
        admin_addr: address,
        day_id: u64,
        subscribers: vector<address>,
        subscriber_units: vector<u64>,
        curators: vector<address>,
        curator_units: vector<u64>,
        amplify_stakers: vector<address>,
        amplify_units: vector<u64>,
        amplify_artists: vector<address>,
    ) acquires Config {
        let cfg = borrow_global_mut<Config<AufiCoinType, SubCoinType>>(admin_addr);
        assert_not_paused(cfg);
        assert_oracle(cfg, signer::address_of(oracle_signer));
        assert!(day_id <= cfg.current_day_id, E_BAD_DAY);
        assert!(!is_true_day(&cfg.day_sealed, day_id), E_DAY_ALREADY_SEALED);
        assert!(vector::length(&subscribers) == vector::length(&subscriber_units), 12001);
        assert!(vector::length(&curators) == vector::length(&curator_units), 12002);
        assert!(vector::length(&amplify_stakers) == vector::length(&amplify_units), 12003);
        assert!(vector::length(&amplify_stakers) == vector::length(&amplify_artists), 12004);

        let registry_admin = cfg.registry_admin;
        let now = timestamp::now_seconds();

        let total_subscriber: u128 = 0;
        let i: u64 = 0;
        let n_subscribers = vector::length(&subscribers);
        while (i < n_subscribers) {
            let u = *vector::borrow(&subscribers, i);

            let active = audiofi_subscriber_graph::is_active_subscriber(registry_admin, u);
            if (!active) {
                i = i + 1;
                continue
            };

            let kdu = key_day_user(day_id, u);
            assert!(!table::contains(&cfg.subscriber_effective, kdu), E_DUPLICATE_ADDRESS);

            let base = (*vector::borrow(&subscriber_units, i) as u128);
            let eff = base;
            table_upsert_vec(&mut cfg.subscriber_effective, kdu, eff);
            total_subscriber = total_subscriber + eff;

            event::emit(SubscriberDaySubmittedEvent {
                day_id,
                user: u,
                base_units: *vector::borrow(&subscriber_units, i),
                effective_units: eff,
                ts: now,
            });

            i = i + 1;
        };

        let total_curator: u128 = 0;
        let j: u64 = 0;
        let n_curators = vector::length(&curators);
        while (j < n_curators) {
            let c = *vector::borrow(&curators, j);

            let active = audiofi_subscriber_graph::is_active_subscriber(registry_admin, c);
            if (!active) {
                j = j + 1;
                continue
            };

            let kdc = key_day_user(day_id, c);
            assert!(!table::contains(&cfg.curator_effective, kdc), E_DUPLICATE_ADDRESS);

            let base = (*vector::borrow(&curator_units, j) as u128);
            table_upsert_vec(&mut cfg.curator_effective, kdc, base);
            total_curator = total_curator + base;

            event::emit(CuratorDaySubmittedEvent {
                day_id,
                curator: c,
                base_units: *vector::borrow(&curator_units, j),
                effective_units: base,
                ts: now,
            });

            j = j + 1;
        };

        let total_amplify: u128 = 0;
        let m: u64 = 0;
        let n_amplify = vector::length(&amplify_stakers);
        while (m < n_amplify) {
            let s = *vector::borrow(&amplify_stakers, m);
            let amplified_artist = *vector::borrow(&amplify_artists, m);

            if (s == amplified_artist) {
                m = m + 1;
                continue
            };

            let active = audiofi_subscriber_graph::is_active_subscriber(registry_admin, s);
            if (!active) {
                m = m + 1;
                continue
            };

            let kds = key_day_user(day_id, s);
            assert!(!table::contains(&cfg.amplify_effective, kds), E_DUPLICATE_ADDRESS);

            let base = (*vector::borrow(&amplify_units, m) as u128);
            let eff = base;
            table_upsert_vec(&mut cfg.amplify_effective, kds, eff);
            total_amplify = total_amplify + eff;

            event::emit(AmplifyDaySubmittedEvent {
                day_id,
                staker: s,
                base_units: *vector::borrow(&amplify_units, m),
                effective_units: eff,
                ts: now,
            });

            m = m + 1;
        };

        table_upsert_u128(&mut cfg.subscriber_total, day_id, total_subscriber);
        table_upsert_u128(&mut cfg.curator_total, day_id, total_curator);
        table_upsert_u128(&mut cfg.amplify_total, day_id, total_amplify);
        table_upsert_bool(&mut cfg.day_sealed, day_id, true);

        let sp = if (table::contains(&cfg.subscriber_pool, day_id)) *table::borrow(&cfg.subscriber_pool, day_id) else 0;
        let cp = if (table::contains(&cfg.curator_pool, day_id)) *table::borrow(&cfg.curator_pool, day_id) else 0;
        let ap = if (table::contains(&cfg.amplify_pool, day_id)) *table::borrow(&cfg.amplify_pool, day_id) else 0;

        event::emit(DaySealedEvent {
            day_id,
            total_subscriber_eff: total_subscriber,
            total_curator_eff: total_curator,
            total_amplify_eff: total_amplify,
            subscriber_pool: sp,
            curator_pool: cp,
            amplify_pool: ap,
            ts: now,
        });
    }


    fun compute_payout(pool: u64, eff: u128, total: u128, max_share_bps: u64): u64 {
        if (total == 0 || pool == 0 || eff == 0) return 0;
        let raw = (((pool as u128) * eff / total) as u64);
        let max_allowed = (pool * max_share_bps) / BPS_DENOM;
        if (raw > max_allowed) { max_allowed } else { raw }
    }

    fun accrue<AufiCoinType, SubCoinType>(cfg: &mut Config<AufiCoinType, SubCoinType>, user: address, payout: u64) {
        let ku = key_addr(user);
        let current = get_pending(&cfg.pending_rewards, &ku);
        if (current == 0) {
            let ku2 = key_addr(user);
            table_upsert_vec(&mut cfg.epoch_start_ts, ku2, timestamp::now_seconds());
        };
        table_upsert_vec(&mut cfg.pending_rewards, ku, current + payout);
    }


    public entry fun auto_claim_subscriber_batch<AufiCoinType, SubCoinType>(
        caller: &signer,
        admin_addr: address,
        day_id: u64,
        users: vector<address>
    ) acquires Config {
        let cfg = borrow_global_mut<Config<AufiCoinType, SubCoinType>>(admin_addr);
        assert_admin_or_system(cfg, signer::address_of(caller));
        assert_not_paused(cfg);
        assert!(is_true_day(&cfg.day_sealed, day_id), E_DAY_NOT_SEALED);

        let now = timestamp::now_seconds();
        let total = *table::borrow(&cfg.subscriber_total, day_id);
        let pool = if (table::contains(&cfg.subscriber_pool, day_id)) *table::borrow(&cfg.subscriber_pool, day_id) else 0;
        let max_share = cfg.max_share_bps;

        let i: u64 = 0;
        let n = vector::length(&users);
        while (i < n) {
            let u = *vector::borrow(&users, i);
            let kdu = key_day_user(day_id, u);
            let already = if (table::contains(&cfg.claimed_subscriber, kdu)) *table::borrow(&cfg.claimed_subscriber, kdu) else false;
            if (!already) {
                let eff = if (table::contains(&cfg.subscriber_effective, kdu)) *table::borrow(&cfg.subscriber_effective, kdu) else 0;
                let payout = compute_payout(pool, eff, total, max_share);
                if (payout > 0) {
                    accrue(cfg, u, payout);
                    table_upsert_vec(&mut cfg.claimed_subscriber, kdu, true);
                    let ku = key_addr(u);
                    let new_pending = get_pending(&cfg.pending_rewards, &ku);
                    event::emit(AccruedSubscriberEvent { day_id, user: u, accrued: payout, total_pending: new_pending, ts: now });
                };
            };
            i = i + 1;
        };
    }

    public entry fun auto_claim_curator_batch<AufiCoinType, SubCoinType>(
        caller: &signer,
        admin_addr: address,
        day_id: u64,
        curators: vector<address>
    ) acquires Config {
        let cfg = borrow_global_mut<Config<AufiCoinType, SubCoinType>>(admin_addr);
        assert_admin_or_system(cfg, signer::address_of(caller));
        assert_not_paused(cfg);
        assert!(is_true_day(&cfg.day_sealed, day_id), E_DAY_NOT_SEALED);

        let now = timestamp::now_seconds();
        let total = *table::borrow(&cfg.curator_total, day_id);
        let pool = if (table::contains(&cfg.curator_pool, day_id)) *table::borrow(&cfg.curator_pool, day_id) else 0;
        let max_share = cfg.max_share_bps;

        let i: u64 = 0;
        let n = vector::length(&curators);
        while (i < n) {
            let c = *vector::borrow(&curators, i);
            let kdc = key_day_user(day_id, c);
            let already = if (table::contains(&cfg.claimed_curator, kdc)) *table::borrow(&cfg.claimed_curator, kdc) else false;
            if (!already) {
                let eff = if (table::contains(&cfg.curator_effective, kdc)) *table::borrow(&cfg.curator_effective, kdc) else 0;
                let payout = compute_payout(pool, eff, total, max_share);
                if (payout > 0) {
                    accrue(cfg, c, payout);
                    table_upsert_vec(&mut cfg.claimed_curator, kdc, true);
                    let kc = key_addr(c);
                    let new_pending = get_pending(&cfg.pending_rewards, &kc);
                    event::emit(AccruedCuratorEvent { day_id, curator: c, accrued: payout, total_pending: new_pending, ts: now });
                };
            };
            i = i + 1;
        };
    }

    public entry fun auto_claim_amplify_batch<AufiCoinType, SubCoinType>(
        caller: &signer,
        admin_addr: address,
        day_id: u64,
        stakers: vector<address>
    ) acquires Config {
        let cfg = borrow_global_mut<Config<AufiCoinType, SubCoinType>>(admin_addr);
        assert_admin_or_system(cfg, signer::address_of(caller));
        assert_not_paused(cfg);
        assert!(is_true_day(&cfg.day_sealed, day_id), E_DAY_NOT_SEALED);

        let now = timestamp::now_seconds();
        let total = *table::borrow(&cfg.amplify_total, day_id);
        let pool = if (table::contains(&cfg.amplify_pool, day_id)) *table::borrow(&cfg.amplify_pool, day_id) else 0;
        let max_share = cfg.max_share_bps;

        let i: u64 = 0;
        let n = vector::length(&stakers);
        while (i < n) {
            let s = *vector::borrow(&stakers, i);
            let kds = key_day_user(day_id, s);
            let already = if (table::contains(&cfg.claimed_amplify, kds)) *table::borrow(&cfg.claimed_amplify, kds) else false;
            if (!already) {
                let eff = if (table::contains(&cfg.amplify_effective, kds)) *table::borrow(&cfg.amplify_effective, kds) else 0;
                let payout = compute_payout(pool, eff, total, max_share);
                if (payout > 0) {
                    accrue(cfg, s, payout);

                    let ks_amp = key_addr(s);
                    let current_amp = get_pending(&cfg.pending_amplify_rewards, &ks_amp);
                    table_upsert_vec(&mut cfg.pending_amplify_rewards, ks_amp, current_amp + payout);

                    table_upsert_vec(&mut cfg.claimed_amplify, kds, true);
                    let ks = key_addr(s);
                    let new_pending = get_pending(&cfg.pending_rewards, &ks);
                    event::emit(AccruedAmplifyEvent { day_id, staker: s, accrued: payout, total_pending: new_pending, ts: now });
                };
            };
            i = i + 1;
        };
    }


    public entry fun claim_rewards<AufiCoinType, SubCoinType>(
        user_signer: &signer,
        admin_addr: address
    ) acquires Config {
        let user = signer::address_of(user_signer);
        let cfg = borrow_global_mut<Config<AufiCoinType, SubCoinType>>(admin_addr);
        assert_not_paused(cfg);

        let now = timestamp::now_seconds();
        let ku = key_addr(user);
        let pending = get_pending(&cfg.pending_rewards, &ku);
        assert!(pending > 0, E_NOTHING_TO_CLAIM);
        assert!(coin::value(&cfg.vault) >= pending, E_NOTHING_TO_CLAIM);

        let epoch_start = get_epoch_start(&cfg.epoch_start_ts, &ku);
        assert!(now >= epoch_start + cfg.epoch_secs, E_EPOCH_NOT_ELAPSED);

        let pay = coin::extract(&mut cfg.vault, pending);
        coin::deposit<AufiCoinType>(user, pay);

        table_upsert_vec(&mut cfg.pending_rewards, ku, 0);
        let ku2 = key_addr(user);
        table_upsert_vec(&mut cfg.pending_amplify_rewards, ku2, 0);

        event::emit(RewardsClaimedEvent { user, claimed: pending, ts: now });
    }


    // apply_amplify_reward_reduction removed — no early exit penalties in the fixed APR model


    #[view]
    public fun view_vault_balance<AufiCoinType, SubCoinType>(admin_addr: address): u64 acquires Config {
        coin::value(&borrow_global<Config<AufiCoinType, SubCoinType>>(admin_addr).vault)
    }

    #[view]
    public fun view_current_day<AufiCoinType, SubCoinType>(admin_addr: address): u64 acquires Config {
        borrow_global<Config<AufiCoinType, SubCoinType>>(admin_addr).current_day_id
    }

    #[view]
    public fun view_emission_params<AufiCoinType, SubCoinType>(admin_addr: address): (u64, u64, u64, u64, u64) acquires Config {
        let cfg = borrow_global<Config<AufiCoinType, SubCoinType>>(admin_addr);
        (cfg.annual_emission_bps, cfg.subscriber_pool_bps, cfg.curator_pool_bps, cfg.amplify_pool_bps, cfg.max_share_bps)
    }

    #[view]
    public fun view_epoch_secs<AufiCoinType, SubCoinType>(admin_addr: address): u64 acquires Config {
        borrow_global<Config<AufiCoinType, SubCoinType>>(admin_addr).epoch_secs
    }

    #[view]
    public fun view_subscriber_pool<AufiCoinType, SubCoinType>(admin_addr: address, day_id: u64): u64 acquires Config {
        let cfg = borrow_global<Config<AufiCoinType, SubCoinType>>(admin_addr);
        if (table::contains(&cfg.subscriber_pool, day_id)) *table::borrow(&cfg.subscriber_pool, day_id) else 0
    }

    #[view]
    public fun view_curator_pool<AufiCoinType, SubCoinType>(admin_addr: address, day_id: u64): u64 acquires Config {
        let cfg = borrow_global<Config<AufiCoinType, SubCoinType>>(admin_addr);
        if (table::contains(&cfg.curator_pool, day_id)) *table::borrow(&cfg.curator_pool, day_id) else 0
    }

    #[view]
    public fun view_amplify_pool<AufiCoinType, SubCoinType>(admin_addr: address, day_id: u64): u64 acquires Config {
        let cfg = borrow_global<Config<AufiCoinType, SubCoinType>>(admin_addr);
        if (table::contains(&cfg.amplify_pool, day_id)) *table::borrow(&cfg.amplify_pool, day_id) else 0
    }

    #[view]
    public fun view_day_sealed<AufiCoinType, SubCoinType>(admin_addr: address, day_id: u64): bool acquires Config {
        is_true_day(&borrow_global<Config<AufiCoinType, SubCoinType>>(admin_addr).day_sealed, day_id)
    }

    #[view]
    public fun view_pending_rewards<AufiCoinType, SubCoinType>(admin_addr: address, user: address): u64 acquires Config {
        let cfg = borrow_global<Config<AufiCoinType, SubCoinType>>(admin_addr);
        let ku = key_addr(user);
        get_pending(&cfg.pending_rewards, &ku)
    }

    #[view]
    public fun view_epoch_start<AufiCoinType, SubCoinType>(admin_addr: address, user: address): u64 acquires Config {
        let cfg = borrow_global<Config<AufiCoinType, SubCoinType>>(admin_addr);
        let ku = key_addr(user);
        get_epoch_start(&cfg.epoch_start_ts, &ku)
    }

    #[view]
    public fun view_pending_amplify_rewards<AufiCoinType, SubCoinType>(admin_addr: address, user: address): u64 acquires Config {
        let cfg = borrow_global<Config<AufiCoinType, SubCoinType>>(admin_addr);
        let ku = key_addr(user);
        get_pending(&cfg.pending_amplify_rewards, &ku)
    }

}
