module audiofi::audiofi_oracle_attest {
    use std::signer;
    use std::table;
    use std::vector;

    use supra_framework::event;
    use supra_framework::timestamp;

    const E_NOT_ADMIN: u64 = 1;
    const E_NOT_ORACLE: u64 = 2;
    const E_PAUSED: u64 = 10;
    const E_ALREADY_INITIALIZED: u64 = 63;
    const E_INVALID_AMOUNT: u64 = 60;
    const E_ALREADY_COMMITTED: u64 = 61;

    #[event]
    struct OracleUpdatedEvent has drop, store {
        oracle: address,
        ts: u64
    }

    #[event]
    struct DayAttestationCommittedEvent has drop, store {
        day_id: u64,
        merkle_root: vector<u8>,
        artist_batch_root: vector<u8>,
        user_batch_root: vector<u8>,
        ts: u64
    }

    struct RootRegistry has key {
        admin: address,
        oracle: address,
        paused: bool,
        day_merkle_root: table::Table<u64, vector<u8>>,
        day_root_committed: table::Table<u64, bool>,
        day_artist_batch_root: table::Table<u64, vector<u8>>,
        day_user_batch_root: table::Table<u64, vector<u8>>,
        day_artist_batch_committed: table::Table<u64, bool>,
        day_user_batch_committed: table::Table<u64, bool>,
    }

    fun assert_admin(cfg: &RootRegistry, caller: address) {
        assert!(caller == cfg.admin, E_NOT_ADMIN);
    }

    fun assert_oracle(cfg: &RootRegistry, caller: address) {
        assert!(caller == cfg.oracle, E_NOT_ORACLE);
    }

    fun assert_not_paused(cfg: &RootRegistry) {
        assert!(!cfg.paused, E_PAUSED);
    }

    fun is_true_day(t: &table::Table<u64, bool>, k: u64): bool {
        if (table::contains(t, k)) *table::borrow(t, k) else false
    }

    public entry fun initialize(
        admin_signer: &signer,
        oracle: address
    ) {
        let admin = signer::address_of(admin_signer);
        assert!(!exists<RootRegistry>(admin), E_ALREADY_INITIALIZED);

        move_to(admin_signer, RootRegistry {
            admin,
            oracle,
            paused: false,
            day_merkle_root: table::new<u64, vector<u8>>(),
            day_root_committed: table::new<u64, bool>(),
            day_artist_batch_root: table::new<u64, vector<u8>>(),
            day_user_batch_root: table::new<u64, vector<u8>>(),
            day_artist_batch_committed: table::new<u64, bool>(),
            day_user_batch_committed: table::new<u64, bool>(),
        });

        event::emit(OracleUpdatedEvent { oracle, ts: timestamp::now_seconds() });
    }

    public entry fun set_oracle(
        admin_signer: &signer,
        admin_addr: address,
        oracle: address
    ) acquires RootRegistry {
        let cfg = borrow_global_mut<RootRegistry>(admin_addr);
        assert_admin(cfg, signer::address_of(admin_signer));
        cfg.oracle = oracle;
        event::emit(OracleUpdatedEvent { oracle, ts: timestamp::now_seconds() });
    }

    public entry fun set_paused(
        admin_signer: &signer,
        admin_addr: address,
        paused: bool
    ) acquires RootRegistry {
        let cfg = borrow_global_mut<RootRegistry>(admin_addr);
        assert_admin(cfg, signer::address_of(admin_signer));
        cfg.paused = paused;
    }

    /// Atomically commit the full immutable day attestation tuple:
    /// day Merkle root + artist batch root + user batch root.
    public entry fun commit_day_attestation(
        oracle_signer: &signer,
        admin_addr: address,
        day_id: u64,
        merkle_root: vector<u8>,
        artist_batch_root: vector<u8>,
        user_batch_root: vector<u8>
    ) acquires RootRegistry {
        let cfg = borrow_global_mut<RootRegistry>(admin_addr);
        assert_not_paused(cfg);
        assert_oracle(cfg, signer::address_of(oracle_signer));
        assert!(vector::length(&merkle_root) == 32, E_INVALID_AMOUNT);
        assert!(vector::length(&artist_batch_root) == 32, E_INVALID_AMOUNT);
        assert!(vector::length(&user_batch_root) == 32, E_INVALID_AMOUNT);
        assert!(!is_true_day(&cfg.day_root_committed, day_id), E_ALREADY_COMMITTED);
        assert!(!is_true_day(&cfg.day_artist_batch_committed, day_id), E_ALREADY_COMMITTED);
        assert!(!is_true_day(&cfg.day_user_batch_committed, day_id), E_ALREADY_COMMITTED);

        table::add(&mut cfg.day_merkle_root, day_id, merkle_root);
        table::add(&mut cfg.day_root_committed, day_id, true);

        table::add(&mut cfg.day_artist_batch_root, day_id, artist_batch_root);
        table::add(&mut cfg.day_artist_batch_committed, day_id, true);

        table::add(&mut cfg.day_user_batch_root, day_id, user_batch_root);
        table::add(&mut cfg.day_user_batch_committed, day_id, true);

        event::emit(DayAttestationCommittedEvent {
            day_id,
            merkle_root: *table::borrow(&cfg.day_merkle_root, day_id),
            artist_batch_root: *table::borrow(&cfg.day_artist_batch_root, day_id),
            user_batch_root: *table::borrow(&cfg.day_user_batch_root, day_id),
            ts: timestamp::now_seconds(),
        });
    }

    #[view]
    public fun view_day_root_committed(admin_addr: address, day_id: u64): bool acquires RootRegistry {
        if (!exists<RootRegistry>(admin_addr)) return false;
        let cfg = borrow_global<RootRegistry>(admin_addr);
        is_true_day(&cfg.day_root_committed, day_id)
    }

    #[view]
    public fun view_day_merkle_root(admin_addr: address, day_id: u64): vector<u8> acquires RootRegistry {
        if (!exists<RootRegistry>(admin_addr)) return vector::empty<u8>();
        let cfg = borrow_global<RootRegistry>(admin_addr);
        if (table::contains(&cfg.day_merkle_root, day_id))
            *table::borrow(&cfg.day_merkle_root, day_id)
        else
            vector::empty<u8>()
    }

    #[view]
    public fun view_artist_batch_root_committed(admin_addr: address, day_id: u64): bool acquires RootRegistry {
        if (!exists<RootRegistry>(admin_addr)) return false;
        let cfg = borrow_global<RootRegistry>(admin_addr);
        is_true_day(&cfg.day_artist_batch_committed, day_id)
    }

    #[view]
    public fun view_user_batch_root_committed(admin_addr: address, day_id: u64): bool acquires RootRegistry {
        if (!exists<RootRegistry>(admin_addr)) return false;
        let cfg = borrow_global<RootRegistry>(admin_addr);
        is_true_day(&cfg.day_user_batch_committed, day_id)
    }

    #[view]
    public fun view_artist_batch_root_matches(
        admin_addr: address,
        day_id: u64,
        batch_root: vector<u8>
    ): bool acquires RootRegistry {
        if (!exists<RootRegistry>(admin_addr)) return false;
        let cfg = borrow_global<RootRegistry>(admin_addr);
        if (!table::contains(&cfg.day_artist_batch_root, day_id)) return false;
        *table::borrow(&cfg.day_artist_batch_root, day_id) == batch_root
    }

    #[view]
    public fun view_user_batch_root_matches(
        admin_addr: address,
        day_id: u64,
        batch_root: vector<u8>
    ): bool acquires RootRegistry {
        if (!exists<RootRegistry>(admin_addr)) return false;
        let cfg = borrow_global<RootRegistry>(admin_addr);
        if (!table::contains(&cfg.day_user_batch_root, day_id)) return false;
        *table::borrow(&cfg.day_user_batch_root, day_id) == batch_root
    }

    #[view]
    public fun view_day_attestation_committed(admin_addr: address, day_id: u64): bool acquires RootRegistry {
        if (!exists<RootRegistry>(admin_addr)) return false;
        let cfg = borrow_global<RootRegistry>(admin_addr);
        is_true_day(&cfg.day_root_committed, day_id)
            && is_true_day(&cfg.day_artist_batch_committed, day_id)
            && is_true_day(&cfg.day_user_batch_committed, day_id)
    }
}
