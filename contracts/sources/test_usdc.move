module audiofi::test_usdc {

    use std::signer;
    use std::string;
    use supra_framework::coin;

    const FAUCET_AMOUNT: u64 = 10_000_000;

    struct TestUSDC has store {}

    struct MintCap has key {
        cap: coin::MintCapability<TestUSDC>
    }

    public entry fun initialize(admin: &signer) {
        let (burn_cap, freeze_cap, mint_cap) =
            coin::initialize<TestUSDC>(
                admin,
                string::utf8(b"Test USD Coin"),
                string::utf8(b"tUSDC"),
                6,
                true
            );

        move_to(admin, MintCap { cap: mint_cap });

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_freeze_cap(freeze_cap);
    }

    public entry fun mint(
        admin: &signer,
        recipient: address,
        amount: u64
    ) acquires MintCap {
        let mint_cap = &borrow_global<MintCap>(signer::address_of(admin)).cap;
        let coins = coin::mint<TestUSDC>(amount, mint_cap);
        coin::deposit(recipient, coins);
    }

    public entry fun register(account: &signer) {
        coin::register<TestUSDC>(account);
    }

    public entry fun faucet(
        user: &signer,
        admin_addr: address
    ) acquires MintCap {
        let user_addr = signer::address_of(user);

        if (!coin::is_account_registered<TestUSDC>(user_addr)) {
            coin::register<TestUSDC>(user);
        };

        let cap = borrow_global<MintCap>(admin_addr);
        let coins = coin::mint<TestUSDC>(FAUCET_AMOUNT, &cap.cap);
        coin::deposit(user_addr, coins);
    }
}
