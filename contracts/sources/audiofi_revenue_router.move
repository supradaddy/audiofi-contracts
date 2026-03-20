module audiofi::audiofi_revenue_router {

    use std::signer;

    use supra_framework::coin;
    use supra_framework::event;
    use supra_framework::timestamp;

    use audiofi::audiofi_subscriber_graph;
    use audiofi::audiofi_stablecoin_autovault;


    const E_NOT_ADMIN: u64 = 1;
    const E_ALREADY_INITIALIZED: u64 = 2;
    const E_PAUSED: u64 = 3;
    const E_INVALID_AMOUNT: u64 = 4;
    const E_BAD_BPS: u64 = 5;
    const E_SELF_SUPPORT: u64 = 6;


    const BPS_DENOM: u64 = 10000;
    const SECS_PER_MONTH: u64 = 30 * 24 * 60 * 60;


    #[event]
    struct RouterConfigEvent has drop, store {
        admin: address,
        platform_treasury: address,
        registry_admin: address,
        autovault_admin: address,
        platform_fee_bps: u64,
        paused: bool,
        ts: u64,
    }

    #[event]
    struct SubscriptionSettlementEvent has drop, store {
        subscriber: address,
        artist: address,
        amount: u64,
        platform_fee: u64,
        creator_share: u64,
        ts: u64,
    }

    #[event]
    struct SubscriptionReceiptsAllocatedEvent has drop, store {
        total_amount: u64,
        treasury_amount: u64,
        vault_amount: u64,
        batch_count: u64,
        ts: u64,
    }


    struct RouterConfig<phantom CoinType> has key {
        admin: address,
        platform_treasury: address,
        registry_admin: address,
        autovault_admin: address,
        platform_fee_bps: u64,
        paused: bool,
    }


    fun assert_admin<CoinType>(cfg: &RouterConfig<CoinType>, caller: address) {
        assert!(caller == cfg.admin, E_NOT_ADMIN);
    }

    fun assert_not_paused<CoinType>(cfg: &RouterConfig<CoinType>) {
        assert!(!cfg.paused, E_PAUSED);
    }


    public entry fun initialize<CoinType>(
        admin_signer: &signer,
        platform_treasury: address,
        registry_admin: address,
        autovault_admin: address,
        platform_fee_bps: u64,
    ) {
        let admin = signer::address_of(admin_signer);
        assert!(!exists<RouterConfig<CoinType>>(admin), E_ALREADY_INITIALIZED);
        assert!(platform_fee_bps <= BPS_DENOM, E_BAD_BPS);

        move_to(admin_signer, RouterConfig<CoinType> {
            admin,
            platform_treasury,
            registry_admin,
            autovault_admin,
            platform_fee_bps,
            paused: false,
        });

        event::emit(RouterConfigEvent {
            admin,
            platform_treasury,
            registry_admin,
            autovault_admin,
            platform_fee_bps,
            paused: false,
            ts: timestamp::now_seconds(),
        });
    }


    public entry fun set_params<CoinType>(
        admin_signer: &signer,
        admin_addr: address,
        platform_treasury: address,
        registry_admin: address,
        autovault_admin: address,
        platform_fee_bps: u64,
        paused: bool,
    ) acquires RouterConfig {
        let cfg = borrow_global_mut<RouterConfig<CoinType>>(admin_addr);
        assert_admin(cfg, signer::address_of(admin_signer));
        assert!(platform_fee_bps <= BPS_DENOM, E_BAD_BPS);

        cfg.platform_treasury = platform_treasury;
        cfg.registry_admin = registry_admin;
        cfg.autovault_admin = autovault_admin;
        cfg.platform_fee_bps = platform_fee_bps;
        cfg.paused = paused;

        event::emit(RouterConfigEvent {
            admin: admin_addr,
            platform_treasury,
            registry_admin,
            autovault_admin,
            platform_fee_bps,
            paused,
            ts: timestamp::now_seconds(),
        });
    }


    public entry fun process_subscription_payment<CoinType>(
        payer_signer: &signer,
        admin_addr: address,
        subscriber: address,
        artist: address,
        amount: u64,
    ) acquires RouterConfig {
        let cfg = borrow_global<RouterConfig<CoinType>>(admin_addr);
        assert_not_paused(cfg);
        assert!(amount > 0, E_INVALID_AMOUNT);
        assert!(subscriber != artist, E_SELF_SUPPORT);

        let platform_fee_bps = cfg.platform_fee_bps;
        let platform_treasury = cfg.platform_treasury;
        let autovault_admin = cfg.autovault_admin;
        let registry_admin = cfg.registry_admin;

        let platform_fee = (((amount as u128) * (platform_fee_bps as u128) / (BPS_DENOM as u128)) as u64);
        let creator_share = amount - platform_fee;

        let payment = coin::withdraw<CoinType>(payer_signer, amount);

        let platform_coin = coin::extract(&mut payment, platform_fee);
        coin::deposit<CoinType>(platform_treasury, platform_coin);

        audiofi_stablecoin_autovault::deposit_subscription_revenue<CoinType>(
            payer_signer,
            autovault_admin,
            payment,
        );

        audiofi_subscriber_graph::renew_subscriber(
            payer_signer,
            registry_admin,
            subscriber,
            artist,
            SECS_PER_MONTH,
        );

        event::emit(SubscriptionSettlementEvent {
            subscriber,
            artist,
            amount,
            platform_fee,
            creator_share,
            ts: timestamp::now_seconds(),
        });
    }


    public entry fun allocate_subscription_receipts<CoinType>(
        receiving_wallet_signer: &signer,
        admin_addr: address,
        amount: u64,
        batch_count: u64,
    ) acquires RouterConfig {
        let cfg = borrow_global<RouterConfig<CoinType>>(admin_addr);
        assert_not_paused(cfg);
        assert!(amount > 0, E_INVALID_AMOUNT);

        let platform_fee_bps = cfg.platform_fee_bps;
        let platform_treasury = cfg.platform_treasury;
        let autovault_admin = cfg.autovault_admin;

        let treasury_amount = (((amount as u128) * (platform_fee_bps as u128) / (BPS_DENOM as u128)) as u64);
        let vault_amount = amount - treasury_amount;

        let payment = coin::withdraw<CoinType>(receiving_wallet_signer, amount);

        let treasury_coin = coin::extract(&mut payment, treasury_amount);
        coin::deposit<CoinType>(platform_treasury, treasury_coin);

        audiofi_stablecoin_autovault::deposit_subscription_revenue<CoinType>(
            receiving_wallet_signer,
            autovault_admin,
            payment,
        );

        event::emit(SubscriptionReceiptsAllocatedEvent {
            total_amount: amount,
            treasury_amount,
            vault_amount,
            batch_count,
            ts: timestamp::now_seconds(),
        });
    }


    #[view]
    public fun view_platform_fee_bps<CoinType>(
        admin_addr: address
    ): u64 acquires RouterConfig {
        borrow_global<RouterConfig<CoinType>>(admin_addr).platform_fee_bps
    }

    #[view]
    public fun view_platform_treasury<CoinType>(
        admin_addr: address
    ): address acquires RouterConfig {
        borrow_global<RouterConfig<CoinType>>(admin_addr).platform_treasury
    }

    #[view]
    public fun view_paused<CoinType>(
        admin_addr: address
    ): bool acquires RouterConfig {
        borrow_global<RouterConfig<CoinType>>(admin_addr).paused
    }

    #[view]
    public fun view_config<CoinType>(
        admin_addr: address
    ): (address, address, address, u64, bool) acquires RouterConfig {
        let cfg = borrow_global<RouterConfig<CoinType>>(admin_addr);
        (
            cfg.platform_treasury,
            cfg.registry_admin,
            cfg.autovault_admin,
            cfg.platform_fee_bps,
            cfg.paused,
        )
    }
}
