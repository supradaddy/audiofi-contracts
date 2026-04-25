/// Direct-to-artist tipping with a small platform fee.
///
/// Split:
///   - 95% to the artist
///   - 5%  to `platform_treasury`
///
/// `platform_treasury` is intended to be the same wallet that receives the
/// 20% subscription fee in `audiofi_subscription_treasurer` (configured to
/// point at the same address off-chain). The treasury wallet then decides,
/// out of band, whether to burn the accumulated AUFI or send it back to the
/// `audiofi_aufi_settlement` vault as additional reward funding. This module
/// deliberately does NOT make that policy choice on-chain.
module audiofi::audiofi_tips_v2 {
    use std::signer;

    use supra_framework::event;
    use supra_framework::fungible_asset;
    use supra_framework::object;
    use supra_framework::primary_fungible_store;
    use supra_framework::timestamp;

    const AUFI_SEED: vector<u8> = b"TestAUFIv4";

    const E_NOT_ADMIN: u64 = 1;
    const E_PAUSED: u64 = 2;
    const E_INVALID_AMOUNT: u64 = 4;
    const E_ALREADY_INITIALIZED: u64 = 5;
    const E_SELF_TIP: u64 = 2001;
    const E_TIP_TREASURY_ADDRESS: u64 = 2002;

    const ARTIST_BPS: u64 = 9500;
    const PLATFORM_FEE_BPS: u64 = 500;
    const MIN_TIP: u64 = 10000;

    #[event]
    struct ConfigUpdatedEvent has drop, store {
        admin: address,
        paused: bool,
        platform_treasury: address,
        ts: u64,
    }

    #[event]
    struct TippedEvent has drop, store {
        from: address,
        to_artist: address,
        amount: u64,
        artist_received: u64,
        platform_fee: u64,
        ts: u64,
    }

    struct Config has key {
        admin: address,
        paused: bool,
        platform_treasury: address,
    }

    fun assert_admin(cfg: &Config, caller: address) {
        assert!(caller == cfg.admin, E_NOT_ADMIN);
    }

    fun get_aufi_metadata(): object::Object<fungible_asset::Metadata> {
        let addr = object::create_object_address(&@audiofi, AUFI_SEED);
        object::address_to_object<fungible_asset::Metadata>(addr)
    }

    public entry fun initialize(
        admin_signer: &signer,
        platform_treasury: address,
    ) {
        let admin = signer::address_of(admin_signer);
        assert!(!exists<Config>(admin), E_ALREADY_INITIALIZED);

        move_to(admin_signer, Config {
            admin,
            paused: false,
            platform_treasury,
        });

        event::emit(ConfigUpdatedEvent {
            admin,
            paused: false,
            platform_treasury,
            ts: timestamp::now_seconds(),
        });
    }

    public entry fun set_paused(
        admin_signer: &signer,
        admin_addr: address,
        paused: bool,
    ) acquires Config {
        let cfg = borrow_global_mut<Config>(admin_addr);
        assert_admin(cfg, signer::address_of(admin_signer));
        cfg.paused = paused;

        event::emit(ConfigUpdatedEvent {
            admin: admin_addr,
            paused,
            platform_treasury: cfg.platform_treasury,
            ts: timestamp::now_seconds(),
        });
    }

    public entry fun set_platform_treasury(
        admin_signer: &signer,
        admin_addr: address,
        new_platform_treasury: address,
    ) acquires Config {
        let cfg = borrow_global_mut<Config>(admin_addr);
        assert_admin(cfg, signer::address_of(admin_signer));
        cfg.platform_treasury = new_platform_treasury;

        event::emit(ConfigUpdatedEvent {
            admin: admin_addr,
            paused: cfg.paused,
            platform_treasury: new_platform_treasury,
            ts: timestamp::now_seconds(),
        });
    }

    public entry fun tip(
        tipper: &signer,
        admin_addr: address,
        artist: address,
        amount: u64,
    ) acquires Config {
        let cfg = borrow_global<Config>(admin_addr);
        assert!(!cfg.paused, E_PAUSED);
        assert!(amount >= MIN_TIP, E_INVALID_AMOUNT);

        let tipper_addr = signer::address_of(tipper);
        assert!(artist != tipper_addr, E_SELF_TIP);

        let platform_treasury = cfg.platform_treasury;
        assert!(artist != platform_treasury, E_TIP_TREASURY_ADDRESS);

        let platform_fee = (((amount as u128) * (PLATFORM_FEE_BPS as u128) / 10000) as u64);
        let artist_received = amount - platform_fee;
        let metadata = get_aufi_metadata();

        primary_fungible_store::transfer(tipper, metadata, platform_treasury, platform_fee);
        primary_fungible_store::transfer(tipper, metadata, artist, artist_received);

        event::emit(TippedEvent {
            from: tipper_addr,
            to_artist: artist,
            amount,
            artist_received,
            platform_fee,
            ts: timestamp::now_seconds(),
        });
    }

    #[view]
    public fun view_artist_bps(): u64 {
        ARTIST_BPS
    }

    #[view]
    public fun view_platform_fee_bps(): u64 {
        PLATFORM_FEE_BPS
    }

    #[view]
    public fun view_min_tip(): u64 {
        MIN_TIP
    }

    #[view]
    public fun view_paused(admin_addr: address): bool acquires Config {
        borrow_global<Config>(admin_addr).paused
    }

    #[view]
    public fun view_platform_treasury(admin_addr: address): address acquires Config {
        borrow_global<Config>(admin_addr).platform_treasury
    }
}
