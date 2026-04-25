/// Subscription treasury router.
/// This module's job is just to:
///
///   1. Route the off-chain-decided split to the platform treasury and
///      the daily-payout vault atomically.
///   2. Anchor the off-chain receipts batch in an event keyed by a
///      `receipts_root`, so external auditors can verify which receipt
///      IDs / amounts went into a given allocation.
///
/// This module deliberately stores no per-subscriber state: subscription
/// identity, expiry, referral boosts and tier multipliers all live off-chain
/// (Postgres) and are committed daily via `audiofi_oracle_attest`.
module audiofi::audiofi_subscription_treasurer {

    use std::signer;

    use supra_framework::coin;
    use supra_framework::event;
    use supra_framework::timestamp;

    use audiofi::audiofi_stablecoin_settlement;


    const E_NOT_ADMIN: u64 = 1;
    const E_ALREADY_INITIALIZED: u64 = 2;
    const E_PAUSED: u64 = 3;
    const E_INVALID_AMOUNT: u64 = 4;
    const E_BAD_RECEIPTS_ROOT: u64 = 5;


    #[event]
    struct TreasurerConfigEvent has drop, store {
        admin: address,
        platform_treasury: address,
        autovault_admin: address,
        paused: bool,
        ts: u64,
    }

    #[event]
    struct SubscriptionReceiptsAllocatedEvent has drop, store {
        /// Total amount transferred from `receiving_wallet_signer`.
        total_amount: u64,
        /// Amount routed to the platform treasury (off-chain decision).
        treasury_amount: u64,
        /// Amount routed to the stablecoin settlement vault for artist
        /// payouts (off-chain decision).
        vault_amount: u64,
        /// Number of off-chain receipts aggregated into this allocation.
        batch_count: u64,
        /// 32-byte SHA-256 root over the (receipt_id, amount) tuples
        /// included in this batch. Auditors can rebuild this off-chain
        /// from the `audiofi_subscription_receipts` table.
        receipts_root: vector<u8>,
        ts: u64,
    }


    struct TreasurerConfig<phantom CoinType> has key {
        admin: address,
        platform_treasury: address,
        autovault_admin: address,
        paused: bool,
    }


    fun assert_admin<CoinType>(cfg: &TreasurerConfig<CoinType>, caller: address) {
        assert!(caller == cfg.admin, E_NOT_ADMIN);
    }

    fun assert_not_paused<CoinType>(cfg: &TreasurerConfig<CoinType>) {
        assert!(!cfg.paused, E_PAUSED);
    }


    public entry fun initialize<CoinType>(
        admin_signer: &signer,
        platform_treasury: address,
        autovault_admin: address,
    ) {
        let admin = signer::address_of(admin_signer);
        assert!(!exists<TreasurerConfig<CoinType>>(admin), E_ALREADY_INITIALIZED);

        move_to(admin_signer, TreasurerConfig<CoinType> {
            admin,
            platform_treasury,
            autovault_admin,
            paused: false,
        });

        event::emit(TreasurerConfigEvent {
            admin,
            platform_treasury,
            autovault_admin,
            paused: false,
            ts: timestamp::now_seconds(),
        });
    }


    public entry fun set_params<CoinType>(
        admin_signer: &signer,
        admin_addr: address,
        platform_treasury: address,
        autovault_admin: address,
        paused: bool,
    ) acquires TreasurerConfig {
        let cfg = borrow_global_mut<TreasurerConfig<CoinType>>(admin_addr);
        assert_admin(cfg, signer::address_of(admin_signer));

        cfg.platform_treasury = platform_treasury;
        cfg.autovault_admin = autovault_admin;
        cfg.paused = paused;

        event::emit(TreasurerConfigEvent {
            admin: admin_addr,
            platform_treasury,
            autovault_admin,
            paused,
            ts: timestamp::now_seconds(),
        });
    }


    /// Lightweight pause/unpause toggle. Use this when the only change you
    /// need is to halt or resume `allocate_subscription_receipts` without
    /// re-supplying the full treasury / autovault address pair to
    /// `set_params`.
    public entry fun set_paused<CoinType>(
        admin_signer: &signer,
        admin_addr: address,
        paused: bool,
    ) acquires TreasurerConfig {
        let cfg = borrow_global_mut<TreasurerConfig<CoinType>>(admin_addr);
        assert_admin(cfg, signer::address_of(admin_signer));

        cfg.paused = paused;

        event::emit(TreasurerConfigEvent {
            admin: admin_addr,
            platform_treasury: cfg.platform_treasury,
            autovault_admin: cfg.autovault_admin,
            paused,
            ts: timestamp::now_seconds(),
        });
    }


    /// Route a Merkle-committed batch of off-chain subscription receipts
    /// from `receiving_wallet_signer` to the platform treasury and the
    /// stablecoin settlement vault.
    ///
    /// The split is decided off-chain (typically by `app/api/cron/allocation-sweep`).
    /// On-chain this module asserts:
    ///   - `treasury_amount + vault_amount > 0`
    ///   - the caller signs over the full transfer (no skim possible by
    ///     a third party)
    ///   - `receipts_root` is exactly 32 bytes
    ///
    /// Auditors can independently rebuild `receipts_root` from the
    /// `audiofi_subscription_receipts` rows aggregated into this batch
    /// and confirm that the on-chain split matches their expected
    /// platform-fee policy.
    public entry fun allocate_subscription_receipts<CoinType>(
        receiving_wallet_signer: &signer,
        admin_addr: address,
        treasury_amount: u64,
        vault_amount: u64,
        batch_count: u64,
        receipts_root: vector<u8>,
    ) acquires TreasurerConfig {
        let cfg = borrow_global<TreasurerConfig<CoinType>>(admin_addr);
        assert_not_paused(cfg);

        let total_amount = treasury_amount + vault_amount;
        assert!(total_amount > 0, E_INVALID_AMOUNT);
        assert!(std::vector::length(&receipts_root) == 32, E_BAD_RECEIPTS_ROOT);

        let platform_treasury = cfg.platform_treasury;
        let autovault_admin = cfg.autovault_admin;

        let payment = coin::withdraw<CoinType>(receiving_wallet_signer, total_amount);

        if (treasury_amount > 0) {
            let treasury_coin = coin::extract(&mut payment, treasury_amount);
            coin::deposit<CoinType>(platform_treasury, treasury_coin);
        };

        // Anything remaining is the vault portion. `deposit_subscription_revenue`
        // requires a positive value, so destroy a zero-value remainder cleanly
        // when the off-chain split routed 100% to the platform treasury.
        if (coin::value(&payment) > 0) {
            audiofi_stablecoin_settlement::deposit_subscription_revenue<CoinType>(
                receiving_wallet_signer,
                autovault_admin,
                payment,
            );
        } else {
            coin::destroy_zero<CoinType>(payment);
        };

        event::emit(SubscriptionReceiptsAllocatedEvent {
            total_amount,
            treasury_amount,
            vault_amount,
            batch_count,
            receipts_root,
            ts: timestamp::now_seconds(),
        });
    }


    #[view]
    public fun view_platform_treasury<CoinType>(
        admin_addr: address
    ): address acquires TreasurerConfig {
        borrow_global<TreasurerConfig<CoinType>>(admin_addr).platform_treasury
    }

    #[view]
    public fun view_autovault_admin<CoinType>(
        admin_addr: address
    ): address acquires TreasurerConfig {
        borrow_global<TreasurerConfig<CoinType>>(admin_addr).autovault_admin
    }

    #[view]
    public fun view_paused<CoinType>(
        admin_addr: address
    ): bool acquires TreasurerConfig {
        borrow_global<TreasurerConfig<CoinType>>(admin_addr).paused
    }

    #[view]
    public fun view_config<CoinType>(
        admin_addr: address
    ): (address, address, address, bool) acquires TreasurerConfig {
        let cfg = borrow_global<TreasurerConfig<CoinType>>(admin_addr);
        (
            cfg.admin,
            cfg.platform_treasury,
            cfg.autovault_admin,
            cfg.paused,
        )
    }
}
