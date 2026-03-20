module audiofi::audiofi_tips {
    use std::signer;

    use supra_framework::coin;
    use supra_framework::event;
    use supra_framework::timestamp;

    const E_NOT_ADMIN: u64 = 1;
    const E_PAUSED: u64 = 2;
    const E_INVALID_AMOUNT: u64 = 4;
    const E_ALREADY_INITIALIZED: u64 = 5;
    const E_SELF_TIP: u64 = 2001;
    const E_TIP_BURN_ADDRESS: u64 = 2002;
    const E_TIP_TREASURY_ADDRESS: u64 = 2003;

    const ARTIST_BPS: u64 = 8000;
    const TREASURY_BPS: u64 = 1500;
    const BURN_BPS: u64 = 500;
    const MIN_TIP: u64 = 10000;

    #[event]
    struct ConfigUpdatedEvent has drop, store {
        admin: address,
        paused: bool,
        burn_address: address,
        treasury_address: address,
        ts: u64,
    }

    #[event]
    struct TippedEvent has drop, store {
        from: address,
        to_artist: address,
        amount: u64,
        artist_received: u64,
        treasury_received: u64,
        burned: u64,
        ts: u64,
    }

    struct Config<phantom CoinType> has key {
        admin: address,
        paused: bool,
        burn_address: address,
        treasury_address: address,
    }

    fun assert_admin<CoinType>(cfg: &Config<CoinType>, caller: address) {
        assert!(caller == cfg.admin, E_NOT_ADMIN);
    }

    public entry fun initialize<CoinType>(
        admin_signer: &signer,
        burn_address: address,
        treasury_address: address
    ) {
        let admin = signer::address_of(admin_signer);
        assert!(!exists<Config<CoinType>>(admin), E_ALREADY_INITIALIZED);

        move_to(admin_signer, Config<CoinType> {
            admin,
            paused: false,
            burn_address,
            treasury_address,
        });

        event::emit(ConfigUpdatedEvent {
            admin,
            paused: false,
            burn_address,
            treasury_address,
            ts: timestamp::now_seconds(),
        });
    }

    public entry fun set_paused<CoinType>(
        admin_signer: &signer,
        admin_addr: address,
        paused: bool
    ) acquires Config {
        let cfg = borrow_global_mut<Config<CoinType>>(admin_addr);
        assert_admin(cfg, signer::address_of(admin_signer));
        cfg.paused = paused;

        event::emit(ConfigUpdatedEvent {
            admin: admin_addr,
            paused,
            burn_address: cfg.burn_address,
            treasury_address: cfg.treasury_address,
            ts: timestamp::now_seconds(),
        });
    }

    public entry fun set_treasury<CoinType>(
        admin_signer: &signer,
        admin_addr: address,
        new_treasury: address
    ) acquires Config {
        let cfg = borrow_global_mut<Config<CoinType>>(admin_addr);
        assert_admin(cfg, signer::address_of(admin_signer));
        cfg.treasury_address = new_treasury;

        event::emit(ConfigUpdatedEvent {
            admin: admin_addr,
            paused: cfg.paused,
            burn_address: cfg.burn_address,
            treasury_address: new_treasury,
            ts: timestamp::now_seconds(),
        });
    }

    public entry fun tip<CoinType>(
        tipper: &signer,
        admin_addr: address,
        artist: address,
        amount: u64
    ) acquires Config {
        let cfg = borrow_global<Config<CoinType>>(admin_addr);
        assert!(!cfg.paused, E_PAUSED);
        assert!(amount >= MIN_TIP, E_INVALID_AMOUNT);

        let tipper_addr = signer::address_of(tipper);
        assert!(artist != tipper_addr, E_SELF_TIP);

        let burn_address = cfg.burn_address;
        let treasury_address = cfg.treasury_address;
        assert!(artist != burn_address, E_TIP_BURN_ADDRESS);
        assert!(artist != treasury_address, E_TIP_TREASURY_ADDRESS);

        let c = coin::withdraw<CoinType>(tipper, amount);

        let burn_amt = (((amount as u128) * (BURN_BPS as u128) / 10000) as u64);
        let treasury_amt = (((amount as u128) * (TREASURY_BPS as u128) / 10000) as u64);

        let burn_coin = coin::extract(&mut c, burn_amt);
        coin::deposit<CoinType>(burn_address, burn_coin);

        let treasury_coin = coin::extract(&mut c, treasury_amt);
        coin::deposit<CoinType>(treasury_address, treasury_coin);

        let to_artist_amt = coin::value(&c);
        coin::deposit<CoinType>(artist, c);

        event::emit(TippedEvent {
            from: tipper_addr,
            to_artist: artist,
            amount,
            artist_received: to_artist_amt,
            treasury_received: treasury_amt,
            burned: burn_amt,
            ts: timestamp::now_seconds(),
        });
    }

    #[view]
    public fun view_artist_bps(): u64 {
        ARTIST_BPS
    }

    #[view]
    public fun view_treasury_bps(): u64 {
        TREASURY_BPS
    }

    #[view]
    public fun view_burn_bps(): u64 {
        BURN_BPS
    }

    #[view]
    public fun view_min_tip(): u64 {
        MIN_TIP
    }

    #[view]
    public fun view_paused<CoinType>(admin_addr: address): bool acquires Config {
        borrow_global<Config<CoinType>>(admin_addr).paused
    }

    #[view]
    public fun view_burn_address<CoinType>(admin_addr: address): address acquires Config {
        borrow_global<Config<CoinType>>(admin_addr).burn_address
    }

    #[view]
    public fun view_treasury_address<CoinType>(admin_addr: address): address acquires Config {
        borrow_global<Config<CoinType>>(admin_addr).treasury_address
    }
}
