/// Daily AUFI emission settlement.
///
/// Splits a fraction of the AUFI vault into a per-day Subscriber pool
/// and a per-day Curator pool, and accrues per-user payouts off a
/// Merkle-attested daily batch from the off-chain oracle. Users claim
/// their accrued AUFI after `epoch_secs` (default 30 days).
///
/// NOTE: Amplify staker rewards are NOT distributed by this module any
/// more. The amplify vault (`audiofi_amplify_vault`) is now a standalone
/// fixed-APR program; its rewards are routed directly into each
/// staker's `audiofi_user_vault` as a 30-day-locked tranche.
module audiofi::audiofi_aufi_settlement_v2 {

    use std::bcs;
    use std::signer;
    use std::table;
    use std::vector;

    use supra_framework::event;
    use supra_framework::fungible_asset;
    use supra_framework::object;
    use supra_framework::primary_fungible_store;
    use supra_framework::timestamp;

    use audiofi::audiofi_oracle_attest;

    const AUFI_SEED: vector<u8> = b"TestAUFIv4";
    const VAULT_SEED: vector<u8> = b"AudioFiAufiSettlementVault";

    const BPS_DENOM: u64 = 10000;
    const SECONDS_PER_YEAR: u64 = 365 * 24 * 60 * 60;

    const DEFAULT_ANNUAL_EMISSION_BPS: u64 = 1800;
    const DEFAULT_SUBSCRIBER_POOL_BPS: u64 = 8000;
    const DEFAULT_CURATOR_POOL_BPS: u64 = 2000;
    const DEFAULT_MAX_SHARE_BPS: u64 = 100;

    const DEFAULT_EPOCH_SECS: u64 = 30 * 24 * 60 * 60;


    const E_NOT_ADMIN: u64 = 1;
    const E_NOT_ORACLE: u64 = 2;
    const E_NOT_SYSTEM_OR_ADMIN: u64 = 3;
    const E_PAUSED: u64 = 10;
    const E_BAD_DAY: u64 = 20;
    const E_DAY_NOT_SEALED: u64 = 21;
    const E_DAY_ALREADY_SEALED: u64 = 22;
    const E_DAY_ROOT_NOT_COMMITTED: u64 = 26;
    const E_BATCH_ROOT_MISMATCH: u64 = 27;
    const E_BAD_POOL_SPLIT: u64 = 23;
    const E_BAD_PARAMS: u64 = 24;
    const E_DUPLICATE_ADDRESS: u64 = 25;
    const E_NOTHING_TO_CLAIM: u64 = 50;
    const E_EPOCH_NOT_ELAPSED: u64 = 53;
    const E_ALREADY_INITIALIZED: u64 = 1000;


    #[event]
    struct ConfigUpdatedEvent has drop, store {
        admin: address,
        system: address,
        oracle: address,
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
        ts: u64,
    }

    #[event]
    struct SubscriberDaySubmittedEvent has drop, store { day_id: u64, user: address, base_units: u64, effective_units: u128, ts: u64 }
    #[event]
    struct CuratorDaySubmittedEvent has drop, store { day_id: u64, curator: address, base_units: u64, effective_units: u128, ts: u64 }
    #[event]
    struct DaySealedEvent has drop, store {
        day_id: u64,
        total_subscriber_eff: u128,
        total_curator_eff: u128,
        subscriber_pool: u64,
        curator_pool: u64,
        ts: u64,
    }

    #[event]
    struct AccruedSubscriberEvent has drop, store { day_id: u64, user: address, accrued: u64, total_pending: u64, ts: u64 }
    #[event]
    struct AccruedCuratorEvent has drop, store { day_id: u64, curator: address, accrued: u64, total_pending: u64, ts: u64 }

    #[event]
    struct RewardsClaimedEvent has drop, store { user: address, claimed: u64, ts: u64 }


    struct Config has key {
        admin: address,
        system: address,
        oracle: address,
        paused: bool,

        current_day_id: u64,

        annual_emission_bps: u64,
        subscriber_pool_bps: u64,
        curator_pool_bps: u64,
        max_share_bps: u64,
        last_emission_ts: u64,

        epoch_secs: u64,

        vault_balance: u64,
        vault_extend_ref: object::ExtendRef,

        subscriber_effective: table::Table<vector<u8>, u128>,
        subscriber_total: table::Table<u64, u128>,

        curator_effective: table::Table<vector<u8>, u128>,
        curator_total: table::Table<u64, u128>,

        subscriber_pool: table::Table<u64, u64>,
        curator_pool: table::Table<u64, u64>,

        day_sealed: table::Table<u64, bool>,

        claimed_subscriber: table::Table<vector<u8>, bool>,
        claimed_curator: table::Table<vector<u8>, bool>,

        pending_rewards: table::Table<vector<u8>, u64>,
        epoch_start_ts: table::Table<vector<u8>, u64>,
    }


    fun key_addr(a: address): vector<u8> { bcs::to_bytes(&a) }

    fun key_day_user(day: u64, a: address): vector<u8> {
        let k = bcs::to_bytes(&day);
        vector::append(&mut k, bcs::to_bytes(&a));
        k
    }


    fun assert_admin(cfg: &Config, caller: address) { assert!(caller == cfg.admin, E_NOT_ADMIN); }
    fun assert_oracle(cfg: &Config, caller: address) { assert!(caller == cfg.oracle, E_NOT_ORACLE); }
    fun assert_admin_or_system(cfg: &Config, caller: address) { assert!(caller == cfg.admin || caller == cfg.system, E_NOT_SYSTEM_OR_ADMIN); }
    fun assert_not_paused(cfg: &Config) { assert!(!cfg.paused, E_PAUSED); }

    fun get_aufi_metadata(): object::Object<fungible_asset::Metadata> {
        let addr = object::create_object_address(&@audiofi, AUFI_SEED);
        object::address_to_object<fungible_asset::Metadata>(addr)
    }

    fun get_vault_address(): address {
        object::create_object_address(&@audiofi, VAULT_SEED)
    }

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


    public entry fun initialize(
        admin_signer: &signer,
        system: address,
        oracle: address,
    ) {
        let admin = signer::address_of(admin_signer);
        assert!(!exists<Config>(admin), E_ALREADY_INITIALIZED);
        assert!(
            DEFAULT_SUBSCRIBER_POOL_BPS + DEFAULT_CURATOR_POOL_BPS == BPS_DENOM,
            E_BAD_POOL_SPLIT
        );

        let constructor_ref = object::create_named_object(admin_signer, VAULT_SEED);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let vault_addr = object::address_from_constructor_ref(&constructor_ref);
        let metadata = get_aufi_metadata();
        primary_fungible_store::ensure_primary_store_exists(vault_addr, metadata);

        move_to(admin_signer, Config {
            admin,
            system,
            oracle,
            paused: false,
            current_day_id: 0,

            annual_emission_bps: DEFAULT_ANNUAL_EMISSION_BPS,
            subscriber_pool_bps: DEFAULT_SUBSCRIBER_POOL_BPS,
            curator_pool_bps: DEFAULT_CURATOR_POOL_BPS,
            max_share_bps: DEFAULT_MAX_SHARE_BPS,
            last_emission_ts: timestamp::now_seconds(),

            epoch_secs: DEFAULT_EPOCH_SECS,

            vault_balance: 0,
            vault_extend_ref: extend_ref,

            subscriber_effective: table::new(),
            subscriber_total: table::new(),

            curator_effective: table::new(),
            curator_total: table::new(),

            subscriber_pool: table::new(),
            curator_pool: table::new(),

            day_sealed: table::new(),
            claimed_subscriber: table::new(),
            claimed_curator: table::new(),

            pending_rewards: table::new(),
            epoch_start_ts: table::new(),
        });

        event::emit(ConfigUpdatedEvent { admin, system, oracle, paused: false, ts: timestamp::now_seconds() });
    }


    public entry fun set_params(
        admin_signer: &signer,
        admin_addr: address,
        system: address,
        oracle: address,
        paused: bool,
        annual_emission_bps: u64,
        subscriber_pool_bps: u64,
        curator_pool_bps: u64,
        max_share_bps: u64,
        epoch_secs: u64,
    ) acquires Config {
        let admin = signer::address_of(admin_signer);
        let cfg = borrow_global_mut<Config>(admin_addr);
        assert_admin(cfg, admin);
        assert!(subscriber_pool_bps + curator_pool_bps == BPS_DENOM, E_BAD_POOL_SPLIT);
        assert!(max_share_bps <= BPS_DENOM, E_BAD_PARAMS);
        assert!(annual_emission_bps <= BPS_DENOM, E_BAD_PARAMS);
        assert!(epoch_secs >= 7 * 24 * 60 * 60, E_BAD_PARAMS);

        cfg.system = system;
        cfg.oracle = oracle;
        cfg.paused = paused;
        cfg.annual_emission_bps = annual_emission_bps;
        cfg.subscriber_pool_bps = subscriber_pool_bps;
        cfg.curator_pool_bps = curator_pool_bps;
        cfg.max_share_bps = max_share_bps;
        cfg.epoch_secs = epoch_secs;

        event::emit(ConfigUpdatedEvent { admin: admin_addr, system, oracle, paused, ts: timestamp::now_seconds() });
    }

    public entry fun fund_vault(
        admin_signer: &signer,
        admin_addr: address,
        amount: u64
    ) acquires Config {
        let admin = signer::address_of(admin_signer);
        let cfg = borrow_global_mut<Config>(admin_addr);
        assert_admin(cfg, admin);

        let metadata = get_aufi_metadata();
        let vault_addr = get_vault_address();
        primary_fungible_store::transfer(admin_signer, metadata, vault_addr, amount);
        cfg.vault_balance = cfg.vault_balance + amount;

        event::emit(VaultFundedEvent { amount, vault_balance: cfg.vault_balance, ts: timestamp::now_seconds() });
    }


    fun emit_for_day(cfg: &mut Config) {
        let now = timestamp::now_seconds();
        let dt = now - cfg.last_emission_ts;
        cfg.last_emission_ts = now;

        let vault_balance = cfg.vault_balance;
        let emitted = (
            (vault_balance as u128)
            * (cfg.annual_emission_bps as u128)
            * (dt as u128)
        ) / ((BPS_DENOM as u128) * (SECONDS_PER_YEAR as u128));

        let emitted_u64 = (emitted as u64);
        if (emitted_u64 == 0) return;

        let subscriber_pool_amt = (emitted_u64 * cfg.subscriber_pool_bps) / BPS_DENOM;
        let curator_pool_amt = (emitted_u64 * cfg.curator_pool_bps) / BPS_DENOM;

        table_upsert_u64(&mut cfg.subscriber_pool, cfg.current_day_id, subscriber_pool_amt);
        table_upsert_u64(&mut cfg.curator_pool, cfg.current_day_id, curator_pool_amt);

        event::emit(EmissionEvent {
            day_id: cfg.current_day_id,
            emitted: emitted_u64,
            subscriber_pool: subscriber_pool_amt,
            curator_pool: curator_pool_amt,
            ts: now,
        });
    }

    public entry fun start_new_day(
        caller: &signer,
        admin_addr: address
    ) acquires Config {
        let cfg = borrow_global_mut<Config>(admin_addr);
        assert_not_paused(cfg);
        assert_admin_or_system(cfg, signer::address_of(caller));

        cfg.current_day_id = cfg.current_day_id + 1;
        emit_for_day(cfg);
    }


    public entry fun submit_day_batch(
        oracle_signer: &signer,
        admin_addr: address,
        day_id: u64,
        subscribers: vector<address>,
        subscriber_units: vector<u64>,
        curators: vector<address>,
        curator_units: vector<u64>,
        batch_root: vector<u8>,
    ) acquires Config {
        let cfg = borrow_global_mut<Config>(admin_addr);
        assert_not_paused(cfg);
        assert_oracle(cfg, signer::address_of(oracle_signer));
        assert!(day_id <= cfg.current_day_id, E_BAD_DAY);
        assert!(!is_true_day(&cfg.day_sealed, day_id), E_DAY_ALREADY_SEALED);
        assert!(
            audiofi_oracle_attest::view_day_attestation_committed(admin_addr, day_id),
            E_DAY_ROOT_NOT_COMMITTED
        );
        assert!(
            audiofi_oracle_attest::view_user_batch_root_matches(admin_addr, day_id, batch_root),
            E_BATCH_ROOT_MISMATCH
        );
        assert!(vector::length(&subscribers) == vector::length(&subscriber_units), 12001);
        assert!(vector::length(&curators) == vector::length(&curator_units), 12002);

        // Caller (oracle) MUST have pre-filtered the inputs to active
        // superfan subscribers / verified curators only; the batch_root
        // cryptographically commits to the exact set of addresses being
        // credited, so any off-chain manipulation will fail attestation
        // verification.
        let now = timestamp::now_seconds();

        let total_subscriber: u128 = 0;
        let i: u64 = 0;
        let n_subscribers = vector::length(&subscribers);
        while (i < n_subscribers) {
            let u = *vector::borrow(&subscribers, i);

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

        table_upsert_u128(&mut cfg.subscriber_total, day_id, total_subscriber);
        table_upsert_u128(&mut cfg.curator_total, day_id, total_curator);
        table_upsert_bool(&mut cfg.day_sealed, day_id, true);

        let sp = if (table::contains(&cfg.subscriber_pool, day_id)) *table::borrow(&cfg.subscriber_pool, day_id) else 0;
        let cp = if (table::contains(&cfg.curator_pool, day_id)) *table::borrow(&cfg.curator_pool, day_id) else 0;

        event::emit(DaySealedEvent {
            day_id,
            total_subscriber_eff: total_subscriber,
            total_curator_eff: total_curator,
            subscriber_pool: sp,
            curator_pool: cp,
            ts: now,
        });
    }


    fun compute_payout(pool: u64, eff: u128, total: u128, max_share_bps: u64): u64 {
        if (total == 0 || pool == 0 || eff == 0) return 0;
        let raw = (((pool as u128) * eff / total) as u64);
        let max_allowed = (pool * max_share_bps) / BPS_DENOM;
        if (raw > max_allowed) { max_allowed } else { raw }
    }

    fun accrue(cfg: &mut Config, user: address, payout: u64) {
        let ku = key_addr(user);
        let current = get_pending(&cfg.pending_rewards, &ku);
        if (current == 0) {
            let ku2 = key_addr(user);
            table_upsert_vec(&mut cfg.epoch_start_ts, ku2, timestamp::now_seconds());
        };
        table_upsert_vec(&mut cfg.pending_rewards, ku, current + payout);
    }


    public entry fun auto_claim_subscriber_batch(
        caller: &signer,
        admin_addr: address,
        day_id: u64,
        users: vector<address>
    ) acquires Config {
        let cfg = borrow_global_mut<Config>(admin_addr);
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

    public entry fun auto_claim_curator_batch(
        caller: &signer,
        admin_addr: address,
        day_id: u64,
        curators: vector<address>
    ) acquires Config {
        let cfg = borrow_global_mut<Config>(admin_addr);
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


    public entry fun claim_rewards(
        user_signer: &signer,
        admin_addr: address
    ) acquires Config {
        let user = signer::address_of(user_signer);
        let cfg = borrow_global_mut<Config>(admin_addr);
        assert_not_paused(cfg);

        let now = timestamp::now_seconds();
        let ku = key_addr(user);
        let pending = get_pending(&cfg.pending_rewards, &ku);
        assert!(pending > 0, E_NOTHING_TO_CLAIM);
        assert!(cfg.vault_balance >= pending, E_NOTHING_TO_CLAIM);

        let epoch_start = get_epoch_start(&cfg.epoch_start_ts, &ku);
        assert!(now >= epoch_start + cfg.epoch_secs, E_EPOCH_NOT_ELAPSED);

        cfg.vault_balance = cfg.vault_balance - pending;
        let vault_signer = object::generate_signer_for_extending(&cfg.vault_extend_ref);
        let metadata = get_aufi_metadata();
        primary_fungible_store::transfer(&vault_signer, metadata, user, pending);

        table_upsert_vec(&mut cfg.pending_rewards, ku, 0);

        event::emit(RewardsClaimedEvent { user, claimed: pending, ts: now });
    }


    #[view]
    public fun view_vault_balance(admin_addr: address): u64 acquires Config {
        borrow_global<Config>(admin_addr).vault_balance
    }

    #[view]
    public fun view_current_day(admin_addr: address): u64 acquires Config {
        borrow_global<Config>(admin_addr).current_day_id
    }

    #[view]
    public fun view_emission_params(admin_addr: address): (u64, u64, u64, u64) acquires Config {
        let cfg = borrow_global<Config>(admin_addr);
        (cfg.annual_emission_bps, cfg.subscriber_pool_bps, cfg.curator_pool_bps, cfg.max_share_bps)
    }

    #[view]
    public fun view_epoch_secs(admin_addr: address): u64 acquires Config {
        borrow_global<Config>(admin_addr).epoch_secs
    }

    #[view]
    public fun view_subscriber_pool(admin_addr: address, day_id: u64): u64 acquires Config {
        let cfg = borrow_global<Config>(admin_addr);
        if (table::contains(&cfg.subscriber_pool, day_id)) *table::borrow(&cfg.subscriber_pool, day_id) else 0
    }

    #[view]
    public fun view_curator_pool(admin_addr: address, day_id: u64): u64 acquires Config {
        let cfg = borrow_global<Config>(admin_addr);
        if (table::contains(&cfg.curator_pool, day_id)) *table::borrow(&cfg.curator_pool, day_id) else 0
    }

    #[view]
    public fun view_day_sealed(admin_addr: address, day_id: u64): bool acquires Config {
        is_true_day(&borrow_global<Config>(admin_addr).day_sealed, day_id)
    }

    #[view]
    public fun view_pending_rewards(admin_addr: address, user: address): u64 acquires Config {
        let cfg = borrow_global<Config>(admin_addr);
        let ku = key_addr(user);
        get_pending(&cfg.pending_rewards, &ku)
    }

    #[view]
    public fun view_epoch_start(admin_addr: address, user: address): u64 acquires Config {
        let cfg = borrow_global<Config>(admin_addr);
        let ku = key_addr(user);
        get_epoch_start(&cfg.epoch_start_ts, &ku)
    }
}
