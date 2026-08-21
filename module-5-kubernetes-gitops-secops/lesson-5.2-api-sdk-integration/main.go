// A minimal OpenBao client that does the three things every application has to
// do for itself on the direct path: authenticate, read, and keep its token alive.
//
//	go run . -addr https://127.0.0.1:8200 -ca /path/to/root_ca.crt \
//	  -role-id "$ROLE_ID" -secret-id "$SECRET_ID"
//
// Add -no-renew to watch the other half of the lesson: the same program with the
// renewal loop switched off, reading in a loop until the token's 60 second TTL
// runs out underneath it.
//
// The only dependency is github.com/openbao/openbao/api/v2 v2.6.0, OpenBao's
// first party Go client. The login below deliberately uses Logical().Write
// rather than a helper package, because it is the same request the curl
// walkthrough makes and the response is worth seeing in full.
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"time"

	openbao "github.com/openbao/openbao/api/v2"
)

func main() {
	addr := flag.String("addr", os.Getenv("BAO_ADDR"), "OpenBao address")
	caCert := flag.String("ca", os.Getenv("BAO_CACERT"), "PEM CA bundle that signed the listener certificate")
	roleID := flag.String("role-id", os.Getenv("ROLE_ID"), "AppRole RoleID")
	secretID := flag.String("secret-id", os.Getenv("SECRET_ID"), "AppRole SecretID")
	path := flag.String("path", "secret/data/apps/reporting", "K/V v2 read path, data/ segment included")
	noRenew := flag.Bool("no-renew", false, "skip the renewal loop, to show what expiry looks like")
	every := flag.Duration("every", 20*time.Second, "how often to re-read the secret")
	runFor := flag.Duration("for", 0, "exit after this long, 0 to run until interrupted")
	flag.Parse()

	if *roleID == "" || *secretID == "" {
		log.Fatal("set -role-id and -secret-id (or ROLE_ID and SECRET_ID)")
	}

	// TLS: verify against the CA that OpenBao's own PKI issued the listener
	// certificate from, in lesson 4.2. There is no skip-verify switch in this
	// program on purpose. A client that will not check the certificate of the
	// service holding its credentials is one bad DNS answer from posting them
	// somewhere else.
	cfg := openbao.DefaultConfig()
	cfg.Address = *addr
	if *caCert != "" {
		if err := cfg.ConfigureTLS(&openbao.TLSConfig{CACert: *caCert}); err != nil {
			log.Fatalf("configuring TLS: %v", err)
		}
	}

	client, err := openbao.NewClient(cfg)
	if err != nil {
		log.Fatalf("creating client: %v", err)
	}

	// 1. Authenticate. RoleID is the username half and can sit in config; the
	// SecretID is the password half and is the one that has to be delivered
	// carefully, which is the whole argument of lesson 2.5.
	auth, err := client.Logical().Write("auth/approle/login", map[string]interface{}{
		"role_id":   *roleID,
		"secret_id": *secretID,
	})
	if err != nil {
		log.Fatalf("login: %v", err)
	}
	if auth == nil || auth.Auth == nil {
		log.Fatal("login returned no auth block")
	}

	client.SetToken(auth.Auth.ClientToken)
	log.Printf("logged in: policies=%v ttl=%ds renewable=%t",
		auth.Auth.TokenPolicies, auth.Auth.LeaseDuration, auth.Auth.Renewable)

	// 2. Keep the token alive, unless we were asked not to.
	//
	// LifetimeWatcher renews in the background at the right moment rather than
	// on a timer of your choosing, and it tells you when renewal has stopped
	// being possible. That second channel is the part people leave out: a token
	// hits token_max_ttl eventually no matter how diligently it is renewed, and
	// an application that treats DoneCh as an error to log will keep running
	// with a credential that no longer works.
	if !*noRenew {
		watcher, err := client.NewLifetimeWatcher(&openbao.LifetimeWatcherInput{Secret: auth})
		if err != nil {
			log.Fatalf("creating lifetime watcher: %v", err)
		}
		go watcher.Start()
		defer watcher.Stop()

		go func() {
			for {
				select {
				case err := <-watcher.DoneCh():
					// Renewal is over. Either it failed, or the token reached
					// its max TTL. Both mean: log in again, now, before the
					// next request needs the token.
					if err != nil {
						log.Printf("renewal stopped with an error: %v", err)
					} else {
						log.Printf("renewal stopped: the token reached token_max_ttl and cannot be renewed again")
					}
					log.Printf("a real application would re-authenticate here rather than carry on")
					return
				case renewal := <-watcher.RenewCh():
					log.Printf("renewed at %s, new ttl=%ds",
						renewal.RenewedAt.Format(time.RFC3339), renewal.Secret.Auth.LeaseDuration)
				}
			}
		}()
	} else {
		log.Printf("renewal disabled: this token expires in %ds", auth.Auth.LeaseDuration)
	}

	// 3. Use it. Reading on a loop is a stand-in for whatever your application
	// actually does; the point is that the token is used repeatedly over a
	// period longer than its TTL.
	deadline := time.Time{}
	if *runFor > 0 {
		deadline = time.Now().Add(*runFor)
	}
	for i := 1; ; i++ {
		if !deadline.IsZero() && time.Now().After(deadline) {
			log.Printf("done: ran for %s", *runFor)
			return
		}
		secret, err := client.Logical().Read(*path)
		if err != nil {
			log.Printf("read %d FAILED: %v", i, err)
			if !*noRenew {
				// Back off rather than spin. A failing read with renewal on
				// usually means the token is gone, and hammering OpenBao with a
				// dead token fills its audit log rather than fixing anything.
				time.Sleep(*every)
				continue
			}
			fmt.Println()
			fmt.Println("That is what an unrenewed token looks like from inside an application.")
			fmt.Println("The request did not fail because OpenBao was down, or because the")
			fmt.Println("secret moved. It failed because nobody renewed the lease.")
			os.Exit(1)
		}
		if secret == nil || secret.Data == nil {
			log.Printf("read %d: no data at %s", i, *path)
		} else {
			data, _ := secret.Data["data"].(map[string]interface{})
			log.Printf("read %d ok: db_url=%v", i, data["db_url"])
		}
		time.Sleep(*every)
	}
}
