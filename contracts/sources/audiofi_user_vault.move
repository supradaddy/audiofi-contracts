module audiofi::audiofi_user_vault {
    use std::signer;
    use std::vector;
    use std::table;

    use supra_framework::object;
    use supra_framework::fungible_asset;
    use supra_framework::primary_fungible_store;
    use supra_framework::timestamp;

    const AUFI_SEED: vector<u8> = b"TestAUFIv4";
    const VAULT_SEED: vector<u8> = b"AudioFiUserVault";

    const LOCK_DURATION_SECS: u64 = 30 * 24 * 60 * 60;

    const E_NOT_ADMIN: u64 = 1;
    const E_NOT_INITIALIZED: u64 = 2;
    const E_INSUFFICIENT_BALANCE: u64 = 3;
    const E_ZERO_AMOUNT: u64 = 4;
    const E_NO_BALANCE: u64 = 5;
    const E_LENGTH_MISMATCH: u64 = 6;

    struct VaultConfig has key {
        fee_address: address,
        reward_source: address,
        discover_cost: u64,
        image_cost: u64,
        video_cost: u64,
        vault_extend_ref: object::ExtendRef,
    }

    struct VideoLongCost has key { value: u64 }

    const DEFAULT_VIDEO_LONG_COST: u64 = 1_500_000_000;

    /// A single tranche of locked rewards. Each daily reward credit creates a
    /// new tranche with its own `lock_until` timestamp so that newer rewards
    /// never extend the lock window of older ones.
    struct Tranche has store, drop, copy {
        amount: u64,
        lock_until: u64,
    }

    struct UserBalance has store, drop {
        available: u64,
        tranches: vector<Tranche>,
    }

    struct UserBalances has key {
        balances: table::Table<address, UserBalance>,
    }

    fun get_aufi_metadata(): object::Object<fungible_asset::Metadata> {
        let addr = object::create_object_address(&@audiofi, AUFI_SEED);
        object::address_to_object<fungible_asset::Metadata>(addr)
    }

    fun get_vault_address(): address {
        object::create_object_address(&@audiofi, VAULT_SEED)
    }

    fun ensure_user(balances: &mut table::Table<address, UserBalance>, user: address) {
        if (!table::contains(balances, user)) {
            table::add(balances, user, UserBalance {
                available: 0,
                tranches: vector::empty<Tranche>(),
            });
        };
    }

    /// Move every tranche whose lock has elapsed into `available`.
    fun try_unlock(bal: &mut UserBalance) {
        let now = timestamp::now_seconds();
        let i: u64 = 0;
        while (i < vector::length(&bal.tranches)) {
            let lock_until = vector::borrow(&bal.tranches, i).lock_until;
            if (now >= lock_until) {
                let amt = vector::borrow(&bal.tranches, i).amount;
                bal.available = bal.available + amt;
                let _removed = vector::remove(&mut bal.tranches, i);
                // Don't advance `i`: subsequent elements shifted left.
            } else {
                i = i + 1;
            };
        };
    }

    /// Sum of all still-locked tranche amounts (post try_unlock).
    fun sum_locked(bal: &UserBalance): u64 {
        let total: u64 = 0;
        let n = vector::length(&bal.tranches);
        let i: u64 = 0;
        while (i < n) {
            total = total + vector::borrow(&bal.tranches, i).amount;
            i = i + 1;
        };
        total
    }

    /// Burn `amount` from locked tranches in FIFO order (oldest credit first).
    /// Caller must guarantee `amount <= sum_locked(bal)`.
    fun deduct_locked_fifo(bal: &mut UserBalance, amount: u64) {
        let remaining = amount;
        while (remaining > 0 && vector::length(&bal.tranches) > 0) {
            let head_amount = vector::borrow(&bal.tranches, 0).amount;
            if (head_amount <= remaining) {
                remaining = remaining - head_amount;
                let _removed = vector::remove(&mut bal.tranches, 0);
            } else {
                let t = vector::borrow_mut(&mut bal.tranches, 0);
                t.amount = head_amount - remaining;
                remaining = 0;
            };
        };
    }

    /// Spend from locked tranches first (even if still locked), then available.
    /// Locked rewards are spendable in Fader actions but not withdrawable.
    fun deduct_spend(bal: &mut UserBalance, cost: u64) {
        try_unlock(bal);
        let locked = sum_locked(bal);
        assert!(bal.available + locked >= cost, E_INSUFFICIENT_BALANCE);
        let from_locked = if (cost <= locked) { cost } else { locked };
        let from_available = cost - from_locked;
        deduct_locked_fifo(bal, from_locked);
        bal.available = bal.available - from_available;
    }

    // -- Admin --

    public entry fun initialize(admin: &signer) {
        assert!(signer::address_of(admin) == @audiofi, E_NOT_ADMIN);

        let constructor_ref = object::create_named_object(admin, VAULT_SEED);
        let extend_ref = object::generate_extend_ref(&constructor_ref);

        move_to(admin, VaultConfig {
            fee_address: @0x3404b97bc101d231897fcc5235524450777a0679b5c7054adc49a654a9fb059b,
            reward_source: @audiofi,
            discover_cost: 10_000_000,
            image_cost:    100_000_000,
            video_cost:    1_000_000_000,
            vault_extend_ref: extend_ref,
        });

        move_to(admin, UserBalances { balances: table::new() });

        let vault_addr = get_vault_address();
        let metadata = get_aufi_metadata();
        primary_fungible_store::ensure_primary_store_exists(vault_addr, metadata);
    }

    public entry fun set_costs(
        admin: &signer, discover: u64, image: u64, video: u64
    ) acquires VaultConfig {
        assert!(signer::address_of(admin) == @audiofi, E_NOT_ADMIN);
        let c = borrow_global_mut<VaultConfig>(@audiofi);
        c.discover_cost = discover;
        c.image_cost = image;
        c.video_cost = video;
    }

    public entry fun set_fee_address(admin: &signer, addr: address) acquires VaultConfig {
        assert!(signer::address_of(admin) == @audiofi, E_NOT_ADMIN);
        borrow_global_mut<VaultConfig>(@audiofi).fee_address = addr;
    }

    public entry fun set_reward_source(admin: &signer, addr: address) acquires VaultConfig {
        assert!(signer::address_of(admin) == @audiofi, E_NOT_ADMIN);
        borrow_global_mut<VaultConfig>(@audiofi).reward_source = addr;
    }

    public entry fun set_video_long_cost(admin: &signer, cost: u64) acquires VideoLongCost {
        assert!(signer::address_of(admin) == @audiofi, E_NOT_ADMIN);
        if (exists<VideoLongCost>(@audiofi)) {
            borrow_global_mut<VideoLongCost>(@audiofi).value = cost;
        } else {
            move_to(admin, VideoLongCost { value: cost });
        };
    }

    fun read_video_long_cost(): u64 acquires VideoLongCost {
        if (exists<VideoLongCost>(@audiofi)) {
            borrow_global<VideoLongCost>(@audiofi).value
        } else {
            DEFAULT_VIDEO_LONG_COST
        }
    }

    // -- User actions --

    public entry fun deposit(user: &signer, amount: u64) acquires UserBalances {
        assert!(amount > 0, E_ZERO_AMOUNT);
        assert!(exists<UserBalances>(@audiofi), E_NOT_INITIALIZED);

        let metadata = get_aufi_metadata();
        let vault_addr = get_vault_address();
        primary_fungible_store::transfer(user, metadata, vault_addr, amount);

        let tbl = &mut borrow_global_mut<UserBalances>(@audiofi).balances;
        let user_addr = signer::address_of(user);
        ensure_user(tbl, user_addr);
        let bal = table::borrow_mut(tbl, user_addr);
        bal.available = bal.available + amount;
    }

    public entry fun withdraw(user: &signer, amount: u64) acquires VaultConfig, UserBalances {
        assert!(amount > 0, E_ZERO_AMOUNT);
        assert!(exists<VaultConfig>(@audiofi), E_NOT_INITIALIZED);

        let user_addr = signer::address_of(user);

        let tbl = &mut borrow_global_mut<UserBalances>(@audiofi).balances;
        assert!(table::contains(tbl, user_addr), E_NO_BALANCE);
        let bal = table::borrow_mut(tbl, user_addr);
        try_unlock(bal);
        assert!(bal.available >= amount, E_INSUFFICIENT_BALANCE);
        bal.available = bal.available - amount;

        let config = borrow_global<VaultConfig>(@audiofi);
        let vault_signer = object::generate_signer_for_extending(&config.vault_extend_ref);
        let metadata = get_aufi_metadata();
        primary_fungible_store::transfer(&vault_signer, metadata, user_addr, amount);
    }

    // -- Backend spend (admin-gated, no user signature) --

    public entry fun spend_discover(admin: &signer, user_addr: address) acquires VaultConfig, UserBalances {
        assert!(signer::address_of(admin) == @audiofi, E_NOT_ADMIN);
        assert!(exists<VaultConfig>(@audiofi), E_NOT_INITIALIZED);

        let config = borrow_global<VaultConfig>(@audiofi);
        let fee = config.fee_address;
        let cost = config.discover_cost;

        let tbl = &mut borrow_global_mut<UserBalances>(@audiofi).balances;
        assert!(table::contains(tbl, user_addr), E_NO_BALANCE);
        deduct_spend(table::borrow_mut(tbl, user_addr), cost);

        let vault_signer = object::generate_signer_for_extending(&config.vault_extend_ref);
        let metadata = get_aufi_metadata();
        primary_fungible_store::transfer(&vault_signer, metadata, fee, cost);
    }

    public entry fun spend_image(admin: &signer, user_addr: address) acquires VaultConfig, UserBalances {
        assert!(signer::address_of(admin) == @audiofi, E_NOT_ADMIN);
        assert!(exists<VaultConfig>(@audiofi), E_NOT_INITIALIZED);

        let config = borrow_global<VaultConfig>(@audiofi);
        let fee = config.fee_address;
        let cost = config.image_cost;

        let tbl = &mut borrow_global_mut<UserBalances>(@audiofi).balances;
        assert!(table::contains(tbl, user_addr), E_NO_BALANCE);
        deduct_spend(table::borrow_mut(tbl, user_addr), cost);

        let vault_signer = object::generate_signer_for_extending(&config.vault_extend_ref);
        let metadata = get_aufi_metadata();
        primary_fungible_store::transfer(&vault_signer, metadata, fee, cost);
    }

    public entry fun spend_video(admin: &signer, user_addr: address) acquires VaultConfig, UserBalances {
        assert!(signer::address_of(admin) == @audiofi, E_NOT_ADMIN);
        assert!(exists<VaultConfig>(@audiofi), E_NOT_INITIALIZED);

        let config = borrow_global<VaultConfig>(@audiofi);
        let fee = config.fee_address;
        let cost = config.video_cost;

        let tbl = &mut borrow_global_mut<UserBalances>(@audiofi).balances;
        assert!(table::contains(tbl, user_addr), E_NO_BALANCE);
        deduct_spend(table::borrow_mut(tbl, user_addr), cost);

        let vault_signer = object::generate_signer_for_extending(&config.vault_extend_ref);
        let metadata = get_aufi_metadata();
        primary_fungible_store::transfer(&vault_signer, metadata, fee, cost);
    }

    public entry fun spend_video_long(admin: &signer, user_addr: address)
        acquires VaultConfig, UserBalances, VideoLongCost {
        assert!(signer::address_of(admin) == @audiofi, E_NOT_ADMIN);
        assert!(exists<VaultConfig>(@audiofi), E_NOT_INITIALIZED);

        let config = borrow_global<VaultConfig>(@audiofi);
        let fee = config.fee_address;
        let cost = read_video_long_cost();

        let tbl = &mut borrow_global_mut<UserBalances>(@audiofi).balances;
        assert!(table::contains(tbl, user_addr), E_NO_BALANCE);
        deduct_spend(table::borrow_mut(tbl, user_addr), cost);

        let vault_signer = object::generate_signer_for_extending(&config.vault_extend_ref);
        let metadata = get_aufi_metadata();
        primary_fungible_store::transfer(&vault_signer, metadata, fee, cost);
    }

    // -- Reward credit (admin sends AUFI into vault, locked 30 days) --

    public entry fun credit_reward(
        admin: &signer, user_addr: address, amount: u64
    ) acquires VaultConfig, UserBalances {
        let caller = signer::address_of(admin);
        let config = borrow_global<VaultConfig>(@audiofi);
        assert!(caller == @audiofi || caller == config.reward_source, E_NOT_ADMIN);
        assert!(amount > 0, E_ZERO_AMOUNT);
        assert!(exists<UserBalances>(@audiofi), E_NOT_INITIALIZED);

        let metadata = get_aufi_metadata();
        let vault_addr = get_vault_address();
        primary_fungible_store::transfer(admin, metadata, vault_addr, amount);

        let tbl = &mut borrow_global_mut<UserBalances>(@audiofi).balances;
        ensure_user(tbl, user_addr);
        let bal = table::borrow_mut(tbl, user_addr);
        try_unlock(bal);
        vector::push_back(&mut bal.tranches, Tranche {
            amount,
            lock_until: timestamp::now_seconds() + LOCK_DURATION_SECS,
        });
    }

    /// Permissionless variant: any signer can fund a 30-day-locked tranche
    /// for `user_addr`. Used by `audiofi_amplify_vault` to route accrued
    /// APR rewards directly into the recipient's user vault, where they
    /// behave identically to daily Pulse rewards (spendable on Fader AI
    /// immediately, withdrawable to wallet after 30 days).
    ///
    /// No admin / reward_source check: the funder is paying real AUFI
    /// out of their own primary store on behalf of the recipient, so the
    /// only effect of an unauthorized call is that the funder gives AUFI
    /// to a user under a 30-day lock.
    public entry fun deposit_locked_tranche(
        funder: &signer,
        user_addr: address,
        amount: u64,
    ) acquires UserBalances {
        assert!(amount > 0, E_ZERO_AMOUNT);
        assert!(exists<UserBalances>(@audiofi), E_NOT_INITIALIZED);

        let metadata = get_aufi_metadata();
        let vault_addr = get_vault_address();
        primary_fungible_store::transfer(funder, metadata, vault_addr, amount);

        let tbl = &mut borrow_global_mut<UserBalances>(@audiofi).balances;
        ensure_user(tbl, user_addr);
        let bal = table::borrow_mut(tbl, user_addr);
        try_unlock(bal);
        vector::push_back(&mut bal.tranches, Tranche {
            amount,
            lock_until: timestamp::now_seconds() + LOCK_DURATION_SECS,
        });
    }

    /// Batch credit: one AUFI transfer for the total, per-user ledger updates.
    /// Reduces gas cost from N txs to 1 tx per batch.
    public entry fun credit_reward_batch(
        admin: &signer,
        users: vector<address>,
        amounts: vector<u64>,
    ) acquires VaultConfig, UserBalances {
        let len = vector::length(&users);
        assert!(len == vector::length(&amounts), E_LENGTH_MISMATCH);
        assert!(len > 0, E_ZERO_AMOUNT);

        let caller = signer::address_of(admin);
        let config = borrow_global<VaultConfig>(@audiofi);
        assert!(caller == @audiofi || caller == config.reward_source, E_NOT_ADMIN);
        assert!(exists<UserBalances>(@audiofi), E_NOT_INITIALIZED);

        let total: u64 = 0;
        let i: u64 = 0;
        while (i < len) {
            total = total + *vector::borrow(&amounts, i);
            i = i + 1;
        };

        let metadata = get_aufi_metadata();
        let vault_addr = get_vault_address();
        primary_fungible_store::transfer(admin, metadata, vault_addr, total);

        let tbl = &mut borrow_global_mut<UserBalances>(@audiofi).balances;
        let now = timestamp::now_seconds();
        let lock_until = now + LOCK_DURATION_SECS;
        let j: u64 = 0;
        while (j < len) {
            let user_addr = *vector::borrow(&users, j);
            let amount = *vector::borrow(&amounts, j);
            if (amount > 0) {
                ensure_user(tbl, user_addr);
                let bal = table::borrow_mut(tbl, user_addr);
                try_unlock(bal);
                vector::push_back(&mut bal.tranches, Tranche {
                    amount,
                    lock_until,
                });
            };
            j = j + 1;
        };
    }

    // -- View functions --

    #[view]
    public fun available_balance(user_addr: address): u64 acquires UserBalances {
        if (!exists<UserBalances>(@audiofi)) return 0;
        let tbl = &borrow_global<UserBalances>(@audiofi).balances;
        if (!table::contains(tbl, user_addr)) return 0;
        let bal = table::borrow(tbl, user_addr);
        let avail = bal.available;
        let now = timestamp::now_seconds();
        let n = vector::length(&bal.tranches);
        let i: u64 = 0;
        while (i < n) {
            let t = vector::borrow(&bal.tranches, i);
            if (now >= t.lock_until) {
                avail = avail + t.amount;
            };
            i = i + 1;
        };
        avail
    }

    #[view]
    public fun locked_balance(user_addr: address): u64 acquires UserBalances {
        if (!exists<UserBalances>(@audiofi)) return 0;
        let tbl = &borrow_global<UserBalances>(@audiofi).balances;
        if (!table::contains(tbl, user_addr)) return 0;
        let bal = table::borrow(tbl, user_addr);
        let now = timestamp::now_seconds();
        let total: u64 = 0;
        let n = vector::length(&bal.tranches);
        let i: u64 = 0;
        while (i < n) {
            let t = vector::borrow(&bal.tranches, i);
            if (now < t.lock_until) {
                total = total + t.amount;
            };
            i = i + 1;
        };
        total
    }

    #[view]
    public fun total_balance(user_addr: address): u64 acquires UserBalances {
        if (!exists<UserBalances>(@audiofi)) return 0;
        let tbl = &borrow_global<UserBalances>(@audiofi).balances;
        if (!table::contains(tbl, user_addr)) return 0;
        let bal = table::borrow(tbl, user_addr);
        let total: u64 = bal.available;
        let n = vector::length(&bal.tranches);
        let i: u64 = 0;
        while (i < n) {
            total = total + vector::borrow(&bal.tranches, i).amount;
            i = i + 1;
        };
        total
    }

    /// Earliest `lock_until` of any still-locked tranche, or 0 if none.
    #[view]
    public fun lock_until(user_addr: address): u64 acquires UserBalances {
        if (!exists<UserBalances>(@audiofi)) return 0;
        let tbl = &borrow_global<UserBalances>(@audiofi).balances;
        if (!table::contains(tbl, user_addr)) return 0;
        let bal = table::borrow(tbl, user_addr);
        let now = timestamp::now_seconds();
        let earliest: u64 = 0;
        let n = vector::length(&bal.tranches);
        let i: u64 = 0;
        while (i < n) {
            let t = vector::borrow(&bal.tranches, i);
            if (now < t.lock_until) {
                if (earliest == 0 || t.lock_until < earliest) {
                    earliest = t.lock_until;
                };
            };
            i = i + 1;
        };
        earliest
    }

    /// Number of currently-tracked tranches for a user (matured + locked).
    /// Useful as a debug/operational view; tranches are removed on unlock or
    /// when fully drained by spending.
    #[view]
    public fun tranche_count(user_addr: address): u64 acquires UserBalances {
        if (!exists<UserBalances>(@audiofi)) return 0;
        let tbl = &borrow_global<UserBalances>(@audiofi).balances;
        if (!table::contains(tbl, user_addr)) return 0;
        vector::length(&table::borrow(tbl, user_addr).tranches)
    }

    #[view]
    public fun discover_cost(): u64 acquires VaultConfig {
        assert!(exists<VaultConfig>(@audiofi), E_NOT_INITIALIZED);
        borrow_global<VaultConfig>(@audiofi).discover_cost
    }

    #[view]
    public fun image_cost(): u64 acquires VaultConfig {
        assert!(exists<VaultConfig>(@audiofi), E_NOT_INITIALIZED);
        borrow_global<VaultConfig>(@audiofi).image_cost
    }

    #[view]
    public fun video_cost(): u64 acquires VaultConfig {
        assert!(exists<VaultConfig>(@audiofi), E_NOT_INITIALIZED);
        borrow_global<VaultConfig>(@audiofi).video_cost
    }

    #[view]
    public fun video_long_cost(): u64 acquires VideoLongCost {
        read_video_long_cost()
    }

    #[view]
    public fun fee_address(): address acquires VaultConfig {
        assert!(exists<VaultConfig>(@audiofi), E_NOT_INITIALIZED);
        borrow_global<VaultConfig>(@audiofi).fee_address
    }

    #[view]
    public fun vault_address(): address {
        get_vault_address()
    }
}
