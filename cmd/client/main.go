package main

import (
	"bufio"
	"flag"
	"fmt"
	"log"
	"os"
	"strings"

	"github.com/coolman7893/distributed-password-manager/pkg/auth"
	appCrypto "github.com/coolman7893/distributed-password-manager/pkg/crypto"
	"github.com/coolman7893/distributed-password-manager/pkg/vault"
)

func main() {
	masterAddr := flag.String("master", "localhost:9000", "Master address")
	certFile := flag.String("cert", "certs/client-cert.pem", "TLS cert")
	keyFile := flag.String("key", "certs/client-key.pem", "TLS key")
	caFile := flag.String("ca", "certs/ca-cert.pem", "CA cert")
	usersFile := flag.String("users", "./data/users.json", "User store path")
	flag.Parse()

	tlsCfg, err := appCrypto.LoadTLSConfig(*certFile, *keyFile, *caFile, false)
	if err != nil {
		log.Fatalf("TLS: %v", err)
	}

	userStore, err := auth.NewUserStore(*usersFile)
	if err != nil {
		log.Fatalf("User store: %v", err)
	}

	scanner := bufio.NewScanner(os.Stdin)
	fmt.Println("=== Distributed Password Manager ===")
	fmt.Println("Commands: register, login, exit")

	var vaultClient *vault.Client

	for {
		if vaultClient != nil {
			fmt.Print("[logged in] > ")
		} else {
			fmt.Print("> ")
		}
		if !scanner.Scan() {
			break
		}
		line := strings.TrimSpace(scanner.Text())
		parts := strings.Fields(line)
		if len(parts) == 0 {
			continue
		}

		switch parts[0] {
		case "register":
			fmt.Print("Username: ")
			scanner.Scan()
			username := strings.TrimSpace(scanner.Text())
			fmt.Print("Master password: ")
			scanner.Scan()
			password := strings.TrimSpace(scanner.Text())
			if err := userStore.Register(username, password); err != nil {
				fmt.Println("Error:", err)
			} else {
				fmt.Println("Registered successfully.")
			}

		case "login":
			fmt.Print("Username: ")
			scanner.Scan()
			username := strings.TrimSpace(scanner.Text())
			fmt.Print("Master password: ")
			scanner.Scan()
			password := strings.TrimSpace(scanner.Text())
			key, _, err := userStore.Login(username, password)
			if err != nil {
				fmt.Println("Login failed:", err)
				continue
			}
			vaultClient = &vault.Client{
				MasterAddr: *masterAddr,
				TLSConfig:  tlsCfg,
				VaultKey:   key,
				Username:   username,
			}
			fmt.Println("Logged in. Commands: save, get, list, delete, logout")

		case "save":
			if vaultClient == nil {
				fmt.Println("Please login first.")
				continue
			}
			fmt.Print("Site: ")
			scanner.Scan()
			site := strings.TrimSpace(scanner.Text())
			fmt.Print("Username: ")
			scanner.Scan()
			user := strings.TrimSpace(scanner.Text())
			fmt.Print("Password: ")
			scanner.Scan()
			pass := strings.TrimSpace(scanner.Text())
			err := vaultClient.Save(vault.PasswordEntry{
				Site: site, Username: user, Password: pass,
			})
			if err != nil {
				fmt.Println("Error:", err)
			} else {
				fmt.Println("Saved.")
			}

		case "get":
			if vaultClient == nil {
				fmt.Println("Please login first.")
				continue
			}
			fmt.Print("Site: ")
			scanner.Scan()
			site := strings.TrimSpace(scanner.Text())
			entry, err := vaultClient.Get(site)
			if err != nil {
				fmt.Println("Error:", err)
			} else {
				fmt.Printf("  Site:     %s\n", entry.Site)
				fmt.Printf("  Username: %s\n", entry.Username)
				fmt.Printf("  Password: %s\n", entry.Password)
			}

		case "list":
			if vaultClient == nil {
				fmt.Println("Please login first.")
				continue
			}
			sites, err := vaultClient.List()
			if err != nil {
				fmt.Println("Error:", err)
			} else if len(sites) == 0 {
				fmt.Println("No passwords stored.")
			} else {
				fmt.Println("Stored sites:")
				for _, s := range sites {
					fmt.Printf("  - %s\n", s)
				}
			}

		case "delete":
			if vaultClient == nil {
				fmt.Println("Please login first.")
				continue
			}
			fmt.Print("Site: ")
			scanner.Scan()
			site := strings.TrimSpace(scanner.Text())
			if err := vaultClient.Delete(site); err != nil {
				fmt.Println("Error:", err)
			} else {
				fmt.Println("Deleted.")
			}

		case "logout":
			vaultClient = nil
			fmt.Println("Logged out.")

		case "exit", "quit":
			fmt.Println("Bye.")
			return

		default:
			fmt.Println("Unknown command:", parts[0])
			if vaultClient != nil {
				fmt.Println("Commands: save, get, list, delete, logout, exit")
			} else {
				fmt.Println("Commands: register, login, exit")
			}
		}
	}
}
