module audiofi::test_aufi_v4 {
    use std::signer;
    use std::string;
    use std::option;

    use supra_framework::fungible_asset;
    use supra_framework::object;
    use supra_framework::primary_fungible_store;

    const TOKEN_SEED: vector<u8> = b"TestAUFIv4";

    const MAX_SUPPLY: u128 = 10_000_000_000_000_000;

    struct AdminRef has key {
        mint_ref: fungible_asset::MintRef,
        burn_ref: fungible_asset::BurnRef,
    }

    fun derive_metadata_address(): address {
        object::create_object_address(&@audiofi, TOKEN_SEED)
    }

    fun get_metadata(): object::Object<fungible_asset::Metadata> {
        object::address_to_object<fungible_asset::Metadata>(derive_metadata_address())
    }

    public entry fun initialize(admin: &signer) {
        let constructor_ref = object::create_named_object(
            admin,
            b"TestAUFIv4",
        );

        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &constructor_ref,
            option::some(MAX_SUPPLY),
            string::utf8(b"Test AUFI Token"),
            string::utf8(b"tAUFI"),
            8,
            string::utf8(b"https://example.com/taufi"),
            string::utf8(b"https://example.com"),
        );

        let mint_ref = fungible_asset::generate_mint_ref(&constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(&constructor_ref);

        move_to(admin, AdminRef {
            mint_ref,
            burn_ref,
        });
    }

    public entry fun mint_to_vault(
        admin: &signer,
        vault_addr: address,
        amount: u64
    ) acquires AdminRef {
        let state = borrow_global<AdminRef>(signer::address_of(admin));
        let fa = fungible_asset::mint(&state.mint_ref, amount);
        primary_fungible_store::deposit(vault_addr, fa);
    }

    public entry fun mint(
        admin: &signer,
        recipient: address,
        amount: u64
    ) acquires AdminRef {
        let state = borrow_global<AdminRef>(signer::address_of(admin));
        let fa = fungible_asset::mint(&state.mint_ref, amount);
        primary_fungible_store::deposit(recipient, fa);
    }

    public entry fun register(account: &signer) {
        let metadata = get_metadata();
        primary_fungible_store::ensure_primary_store_exists(
            signer::address_of(account),
            metadata,
        );
    }

    public entry fun faucet(
        user: &signer,
        admin_addr: address
    ) acquires AdminRef {
        let user_addr = signer::address_of(user);
        let metadata = get_metadata();
        primary_fungible_store::ensure_primary_store_exists(user_addr, metadata);

        let state = borrow_global<AdminRef>(admin_addr);
        let fa = fungible_asset::mint(&state.mint_ref, 100_000_000_000);
        primary_fungible_store::deposit(user_addr, fa);
    }

    #[view]
    public fun balance_of(owner: address): u64 {
        let metadata = get_metadata();
        primary_fungible_store::balance(owner, metadata)
    }

    #[view]
    public fun supply(): u128 {
        let metadata = get_metadata();
        let supply_opt = fungible_asset::supply(metadata);
        option::get_with_default(&supply_opt, 0)
    }

    #[view]
    public fun metadata_address(): address {
        derive_metadata_address()
    }
}
