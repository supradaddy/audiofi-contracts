module audiofi::audiofi_subscriber_graph {

    use std::bcs;
    use std::signer;
    use std::table;
    use std::vector;

    use supra_framework::event;
    use supra_framework::timestamp;


    const E_NOT_ADMIN: u64 = 1;
    const E_NOT_SYSTEM: u64 = 2;
    const E_ALREADY_INITIALIZED: u64 = 3;
    const E_PAUSED: u64 = 4;
    const E_ALREADY_REGISTERED: u64 = 10;
    const E_NOT_REGISTERED: u64 = 11;
    const E_SELF_SUPPORT: u64 = 12;
    const E_ARTIST_MISMATCH: u64 = 13;
    const E_INVALID_EXPIRY: u64 = 14;


    #[event]
    struct GraphConfigEvent has drop, store {
        admin: address,
        system: address,
        paused: bool,
        ts: u64,
    }

    #[event]
    struct SubscriberRegisteredEvent has drop, store {
        subscriber: address,
        artist: address,
        expires_at: u64,
        is_first_ever: bool,
        ts: u64,
    }

    #[event]
    struct SubscriberRenewedEvent has drop, store {
        subscriber: address,
        artist: address,
        old_expires_at: u64,
        new_expires_at: u64,
        ts: u64,
    }

    #[event]
    struct SubscriberClearedEvent has drop, store {
        subscriber: address,
        artist: address,
        reason: u8,
        ts: u64,
    }

    #[event]
    struct SubscriberSwitchedEvent has drop, store {
        subscriber: address,
        old_artist: address,
        new_artist: address,
        new_expires_at: u64,
        ts: u64,
    }

    #[event]
    struct ArtistThresholdReachedEvent has drop, store {
        artist: address,
        subscriber_count: u64,
        ts: u64,
    }

    #[event]
    struct ReferralBoostSetEvent has drop, store {
        subscriber: address,
        referred_artist: address,
        boost_bps: u64,
        expires_at: u64,
        ts: u64,
    }


    const CLEAR_REASON_EXPIRED: u8 = 0;
    const CLEAR_REASON_CANCELLED: u8 = 1;
    const CLEAR_REASON_ADMIN: u8 = 2;


    const REFERRAL_BOOST_BPS: u64 = 1000;
    const REFERRAL_BOOST_DURATION_SECS: u64 = 7776000;


    struct SubscriberRecord has store, drop, copy {
        artist: address,
        registered_at: u64,
        expires_at: u64,
        is_first_ever: bool,
    }

    struct ReferralBoost has store, drop, copy {
        referred_artist: address,
        boost_bps: u64,
        expires_at: u64,
    }

    struct ArtistStats has store, drop, copy {
        total_credited_subscribers: u64,
        active_subscriber_count: u64,
        threshold_reached: bool,
    }

    struct SubscriberGraph has key {
        admin: address,
        system: address,
        paused: bool,

        records: table::Table<vector<u8>, SubscriberRecord>,
        ever_been_subscriber: table::Table<vector<u8>, bool>,
        artist_stats: table::Table<vector<u8>, ArtistStats>,
        referral_boosts: table::Table<vector<u8>, ReferralBoost>,
    }


    fun key_addr(a: address): vector<u8> { bcs::to_bytes(&a) }


    fun assert_admin(r: &SubscriberGraph, caller: address) {
        assert!(caller == r.admin, E_NOT_ADMIN);
    }

    fun assert_system(r: &SubscriberGraph, caller: address) {
        assert!(caller == r.system, E_NOT_SYSTEM);
    }

    fun assert_not_paused(r: &SubscriberGraph) {
        assert!(!r.paused, E_PAUSED);
    }


    fun upsert_record(t: &mut table::Table<vector<u8>, SubscriberRecord>, k: vector<u8>, v: SubscriberRecord) {
        if (table::contains(t, k)) {
            *table::borrow_mut(t, k) = v;
        } else {
            table::add(t, k, v);
        };
    }

    fun upsert_stats(t: &mut table::Table<vector<u8>, ArtistStats>, k: vector<u8>, v: ArtistStats) {
        if (table::contains(t, k)) {
            *table::borrow_mut(t, k) = v;
        } else {
            table::add(t, k, v);
        };
    }

    fun upsert_bool(t: &mut table::Table<vector<u8>, bool>, k: vector<u8>, v: bool) {
        if (table::contains(t, k)) {
            *table::borrow_mut(t, k) = v;
        } else {
            table::add(t, k, v);
        };
    }

    fun get_stats(t: &table::Table<vector<u8>, ArtistStats>, k: &vector<u8>): ArtistStats {
        if (table::contains(t, *k)) {
            *table::borrow(t, *k)
        } else {
            ArtistStats { total_credited_subscribers: 0, active_subscriber_count: 0, threshold_reached: false }
        }
    }

    fun increment_credited_stats(
        artist_stats: &mut table::Table<vector<u8>, ArtistStats>,
        artist: address,
        now: u64,
    ) {
        let ka = key_addr(artist);
        let stats = get_stats(artist_stats, &ka);
        let new_count = stats.total_credited_subscribers + 1;
        let threshold = new_count >= 5;
        upsert_stats(artist_stats, ka, ArtistStats {
            total_credited_subscribers: new_count,
            active_subscriber_count: stats.active_subscriber_count,
            threshold_reached: threshold || stats.threshold_reached,
        });

        if (threshold && !stats.threshold_reached) {
            event::emit(ArtistThresholdReachedEvent {
                artist,
                subscriber_count: new_count,
                ts: now,
            });
        };
    }

    fun increment_active_count(
        artist_stats: &mut table::Table<vector<u8>, ArtistStats>,
        artist: address,
    ) {
        let ka = key_addr(artist);
        let stats = get_stats(artist_stats, &ka);
        upsert_stats(artist_stats, ka, ArtistStats {
            total_credited_subscribers: stats.total_credited_subscribers,
            active_subscriber_count: stats.active_subscriber_count + 1,
            threshold_reached: stats.threshold_reached,
        });
    }

    fun decrement_active_count(
        artist_stats: &mut table::Table<vector<u8>, ArtistStats>,
        artist: address,
    ) {
        let ka = key_addr(artist);
        let stats = get_stats(artist_stats, &ka);
        if (stats.active_subscriber_count > 0) {
            upsert_stats(artist_stats, ka, ArtistStats {
                total_credited_subscribers: stats.total_credited_subscribers,
                active_subscriber_count: stats.active_subscriber_count - 1,
                threshold_reached: stats.threshold_reached,
            });
        };
    }


    public entry fun initialize(
        admin_signer: &signer,
        system: address,
    ) {
        let admin = signer::address_of(admin_signer);
        assert!(!exists<SubscriberGraph>(admin), E_ALREADY_INITIALIZED);

        move_to(admin_signer, SubscriberGraph {
            admin,
            system,
            paused: false,
            records: table::new(),
            ever_been_subscriber: table::new(),
            artist_stats: table::new(),
            referral_boosts: table::new(),
        });

        event::emit(GraphConfigEvent { admin, system, paused: false, ts: timestamp::now_seconds() });
    }


    public entry fun set_params(
        admin_signer: &signer,
        admin_addr: address,
        system: address,
        paused: bool,
    ) acquires SubscriberGraph {
        let r = borrow_global_mut<SubscriberGraph>(admin_addr);
        assert_admin(r, signer::address_of(admin_signer));

        r.system = system;
        r.paused = paused;

        event::emit(GraphConfigEvent { admin: admin_addr, system, paused, ts: timestamp::now_seconds() });
    }


    public entry fun register_subscriber(
        caller: &signer,
        admin_addr: address,
        subscriber: address,
        artist: address,
        expires_at: u64,
    ) acquires SubscriberGraph {
        let r = borrow_global_mut<SubscriberGraph>(admin_addr);
        assert_system(r, signer::address_of(caller));
        assert_not_paused(r);
        assert!(subscriber != artist, E_SELF_SUPPORT);
        assert!(expires_at > timestamp::now_seconds(), E_INVALID_EXPIRY);

        let ks = key_addr(subscriber);

        if (table::contains(&r.records, ks)) {
            let existing = table::borrow(&r.records, ks);
            let now = timestamp::now_seconds();
            assert!(now > existing.expires_at, E_ALREADY_REGISTERED);
        };

        let is_first = !table::contains(&r.ever_been_subscriber, ks) ||
                        !*table::borrow(&r.ever_been_subscriber, ks);

        let now = timestamp::now_seconds();

        let record = SubscriberRecord {
            artist,
            registered_at: now,
            expires_at,
            is_first_ever: is_first,
        };
        upsert_record(&mut r.records, ks, record);

        if (is_first) {
            upsert_bool(&mut r.ever_been_subscriber, ks, true);
            increment_credited_stats(&mut r.artist_stats, artist, now);
        };
        increment_active_count(&mut r.artist_stats, artist);

        event::emit(SubscriberRegisteredEvent {
            subscriber,
            artist,
            expires_at,
            is_first_ever: is_first,
            ts: now,
        });
    }


    public entry fun renew_subscriber(
        caller: &signer,
        admin_addr: address,
        subscriber: address,
        artist: address,
        extension_secs: u64,
    ) acquires SubscriberGraph {
        let r = borrow_global_mut<SubscriberGraph>(admin_addr);
        assert_system(r, signer::address_of(caller));
        assert_not_paused(r);
        assert!(subscriber != artist, E_SELF_SUPPORT);

        let ks = key_addr(subscriber);
        let now = timestamp::now_seconds();

        if (!table::contains(&r.records, ks)) {
            let is_first = !table::contains(&r.ever_been_subscriber, ks) ||
                            !*table::borrow(&r.ever_been_subscriber, ks);

            let new_expires = now + extension_secs;
            upsert_record(&mut r.records, ks, SubscriberRecord {
                artist,
                registered_at: now,
                expires_at: new_expires,
                is_first_ever: is_first,
            });

            if (is_first) {
                upsert_bool(&mut r.ever_been_subscriber, ks, true);
                increment_credited_stats(&mut r.artist_stats, artist, now);
            };
            increment_active_count(&mut r.artist_stats, artist);

            event::emit(SubscriberRegisteredEvent {
                subscriber,
                artist,
                expires_at: new_expires,
                is_first_ever: is_first,
                ts: now,
            });
        } else {
            let existing = *table::borrow(&r.records, ks);

            if (now <= existing.expires_at) {
                assert!(existing.artist == artist, E_ARTIST_MISMATCH);
                let new_expires = existing.expires_at + extension_secs;
                upsert_record(&mut r.records, ks, SubscriberRecord {
                    artist,
                    registered_at: existing.registered_at,
                    expires_at: new_expires,
                    is_first_ever: existing.is_first_ever,
                });

                event::emit(SubscriberRenewedEvent {
                    subscriber,
                    artist,
                    old_expires_at: existing.expires_at,
                    new_expires_at: new_expires,
                    ts: now,
                });
            } else {
                let new_expires = now + extension_secs;
                upsert_record(&mut r.records, ks, SubscriberRecord {
                    artist,
                    registered_at: now,
                    expires_at: new_expires,
                    is_first_ever: false,
                });

                if (existing.artist != artist) {
                    increment_credited_stats(&mut r.artist_stats, artist, now);
                };
                increment_active_count(&mut r.artist_stats, artist);

                event::emit(SubscriberRegisteredEvent {
                    subscriber,
                    artist,
                    expires_at: new_expires,
                    is_first_ever: false,
                    ts: now,
                });
            };
        };
    }


    public entry fun clear_subscriber(
        caller: &signer,
        admin_addr: address,
        subscriber: address,
        reason: u8,
    ) acquires SubscriberGraph {
        let r = borrow_global_mut<SubscriberGraph>(admin_addr);
        assert_system(r, signer::address_of(caller));
        assert_not_paused(r);

        let ks = key_addr(subscriber);
        assert!(table::contains(&r.records, ks), E_NOT_REGISTERED);

        let old_record = *table::borrow(&r.records, ks);
        let now = timestamp::now_seconds();
        if (now <= old_record.expires_at) {
            decrement_active_count(&mut r.artist_stats, old_record.artist);
        };
        table::remove(&mut r.records, ks);

        event::emit(SubscriberClearedEvent {
            subscriber,
            artist: old_record.artist,
            reason,
            ts: now,
        });
    }

    public entry fun clear_subscriber_batch(
        caller: &signer,
        admin_addr: address,
        subscribers: vector<address>,
        reason: u8,
    ) acquires SubscriberGraph {
        let r = borrow_global_mut<SubscriberGraph>(admin_addr);
        assert_system(r, signer::address_of(caller));
        assert_not_paused(r);

        let now = timestamp::now_seconds();
        let i: u64 = 0;
        let n = vector::length(&subscribers);
        while (i < n) {
            let sf = *vector::borrow(&subscribers, i);
            let ks = key_addr(sf);
            if (table::contains(&r.records, ks)) {
                let old_record = *table::borrow(&r.records, ks);
                if (now <= old_record.expires_at) {
                    decrement_active_count(&mut r.artist_stats, old_record.artist);
                };
                table::remove(&mut r.records, ks);
                event::emit(SubscriberClearedEvent {
                    subscriber: sf,
                    artist: old_record.artist,
                    reason,
                    ts: now,
                });
            };
            i = i + 1;
        };
    }


    public entry fun switch_subscription_artist(
        caller: &signer,
        admin_addr: address,
        subscriber: address,
        new_artist: address,
        new_expires_at: u64,
    ) acquires SubscriberGraph {
        let r = borrow_global_mut<SubscriberGraph>(admin_addr);
        assert_system(r, signer::address_of(caller));
        assert_not_paused(r);
        assert!(subscriber != new_artist, E_SELF_SUPPORT);
        assert!(new_expires_at > timestamp::now_seconds(), E_INVALID_EXPIRY);

        let ks = key_addr(subscriber);
        let now = timestamp::now_seconds();

        let old_artist =
            if (table::contains(&r.records, ks)) {
                let existing = table::borrow(&r.records, ks);
                assert!(now > existing.expires_at, E_ALREADY_REGISTERED);
                existing.artist
            } else {
                @0x0
            };

        let record = SubscriberRecord {
            artist: new_artist,
            registered_at: now,
            expires_at: new_expires_at,
            is_first_ever: false,
        };
        upsert_record(&mut r.records, ks, record);
        increment_active_count(&mut r.artist_stats, new_artist);

        event::emit(SubscriberSwitchedEvent {
            subscriber,
            old_artist,
            new_artist,
            new_expires_at,
            ts: now,
        });
    }


    #[view]
    public fun view_subscriber_record(admin_addr: address, subscriber: address): (address, u64, u64, bool) acquires SubscriberGraph {
        let r = borrow_global<SubscriberGraph>(admin_addr);
        let ks = key_addr(subscriber);
        if (!table::contains(&r.records, ks)) return (@0x0, 0, 0, false);
        let rec = table::borrow(&r.records, ks);
        (rec.artist, rec.registered_at, rec.expires_at, rec.is_first_ever)
    }

    #[view]
    public fun is_active_subscriber(admin_addr: address, subscriber: address): bool acquires SubscriberGraph {
        let r = borrow_global<SubscriberGraph>(admin_addr);
        let ks = key_addr(subscriber);
        if (!table::contains(&r.records, ks)) return false;
        let rec = table::borrow(&r.records, ks);
        timestamp::now_seconds() <= rec.expires_at
    }

    #[view]
    public fun view_artist_stats(admin_addr: address, artist: address): (u64, u64, bool) acquires SubscriberGraph {
        let r = borrow_global<SubscriberGraph>(admin_addr);
        let ka = key_addr(artist);
        let stats = get_stats(&r.artist_stats, &ka);
        (stats.active_subscriber_count, stats.total_credited_subscribers, stats.threshold_reached)
    }

    #[view]
    public fun has_ever_been_subscriber(admin_addr: address, user: address): bool acquires SubscriberGraph {
        let r = borrow_global<SubscriberGraph>(admin_addr);
        let k = key_addr(user);
        if (!table::contains(&r.ever_been_subscriber, k)) return false;
        *table::borrow(&r.ever_been_subscriber, k)
    }


    public entry fun set_referral_boost(
        caller: &signer,
        admin_addr: address,
        subscriber: address,
        referred_artist: address,
    ) acquires SubscriberGraph {
        let r = borrow_global_mut<SubscriberGraph>(admin_addr);
        assert_system(r, signer::address_of(caller));
        assert_not_paused(r);
        assert!(subscriber != referred_artist, E_SELF_SUPPORT);

        let now = timestamp::now_seconds();
        let expires_at = now + REFERRAL_BOOST_DURATION_SECS;

        let ks = key_addr(subscriber);
        let boost = ReferralBoost {
            referred_artist,
            boost_bps: REFERRAL_BOOST_BPS,
            expires_at,
        };

        if (table::contains(&r.referral_boosts, ks)) {
            *table::borrow_mut(&mut r.referral_boosts, ks) = boost;
        } else {
            table::add(&mut r.referral_boosts, ks, boost);
        };

        event::emit(ReferralBoostSetEvent {
            subscriber,
            referred_artist,
            boost_bps: REFERRAL_BOOST_BPS,
            expires_at,
            ts: now,
        });
    }

    #[view]
    public fun view_referral_boost(
        admin_addr: address,
        subscriber: address,
    ): (bool, address, u64, u64) acquires SubscriberGraph {
        let r = borrow_global<SubscriberGraph>(admin_addr);
        let ks = key_addr(subscriber);
        if (!table::contains(&r.referral_boosts, ks)) return (false, @0x0, 0, 0);
        let boost = table::borrow(&r.referral_boosts, ks);
        if (timestamp::now_seconds() > boost.expires_at) return (false, @0x0, 0, 0);
        (true, boost.referred_artist, boost.boost_bps, boost.expires_at)
    }

    #[view]
    public fun has_active_referral_boost_for_artist(
        admin_addr: address,
        subscriber: address,
        artist: address,
    ): bool acquires SubscriberGraph {
        let r = borrow_global<SubscriberGraph>(admin_addr);
        let ks = key_addr(subscriber);
        if (!table::contains(&r.referral_boosts, ks)) return false;
        let boost = table::borrow(&r.referral_boosts, ks);
        boost.referred_artist == artist && timestamp::now_seconds() <= boost.expires_at
    }

}
