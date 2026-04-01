package main

import (
	"bufio"
	"bytes"
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"

	appCrypto "github.com/coolman7893/distributed-password-manager/pkg/crypto"
)

// httpClient is a small helper that talks to the master's HTTPS REST API.
// It mirrors what the web UI does, so both share the same user store on
// the master VM.
type httpClient struct {
	baseURL    string
	httpClient *http.Client
	// sessionCookie is stored after login so subsequent requests are authenticated.
	sessionCookie *http.Cookie
}

func newHTTPClient(masterHTTPAddr string, tlsCfg *tls.Config) *httpClient {
	return &httpClient{
		baseURL: "https://" + masterHTTPAddr,
		httpClient: &http.Client{
			Transport: &http.Transport{TLSClientConfig: tlsCfg},
		},
	}
}

func (c *httpClient) post(path string, body interface{}) (*http.Response, []byte, error) {
	b, err := json.Marshal(body)
	if err != nil {
		return nil, nil, err
	}
	req, err := http.NewRequest("POST", c.baseURL+path, bytes.NewReader(b))
	if err != nil {
		return nil, nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	if c.sessionCookie != nil {
		req.AddCookie(c.sessionCookie)
	}
	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, nil, err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return resp, data, nil
}

func (c *httpClient) get(path string) (*http.Response, []byte, error) {
	req, err := http.NewRequest("GET", c.baseURL+path, nil)
	if err != nil {
		return nil, nil, err
	}
	if c.sessionCookie != nil {
		req.AddCookie(c.sessionCookie)
	}
	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, nil, err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return resp, data, nil
}

func (c *httpClient) delete(path string) (*http.Response, []byte, error) {
	req, err := http.NewRequest("DELETE", c.baseURL+path, nil)
	if err != nil {
		return nil, nil, err
	}
	if c.sessionCookie != nil {
		req.AddCookie(c.sessionCookie)
	}
	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, nil, err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return resp, data, nil
}

func (c *httpClient) register(username, password string) error {
	resp, data, err := c.post("/auth/register", map[string]string{
		"username": username,
		"password": password,
	})
	if err != nil {
		return err
	}
	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusCreated {
		var e map[string]string
		json.Unmarshal(data, &e)
		if msg, ok := e["error"]; ok {
			return fmt.Errorf("%s", msg)
		}
		return fmt.Errorf("registration failed (HTTP %d)", resp.StatusCode)
	}
	return nil
}

// login authenticates against the master HTTP API, stores the session cookie,
// and returns the vault key derived from the password (same derivation the
// master uses — PBKDF2 with the salt stored on the master).
// We call /auth/login to verify credentials and get the session, but we still
// need the salt to derive the vault key locally so we can encrypt/decrypt.
// The master's /auth/login endpoint returns the username; we fetch the salt
// via a separate lightweight mechanism by re-deriving after successful auth.
//
// Implementation note: the master's HTTP login sets a session cookie and the
// vault key is derived server-side from the stored salt. Since the CLI needs
// the vault key locally for AES operations we use the gob master port for the
// actual vault operations (same as before). We only use HTTP for register/login
// auth so both CLI and UI share the same users.json on the master.
func (c *httpClient) login(username, password string) error {
	resp, data, err := c.post("/auth/login", map[string]string{
		"username": username,
		"password": password,
	})
	if err != nil {
		return err
	}
	if resp.StatusCode != http.StatusOK {
		var e map[string]string
		json.Unmarshal(data, &e)
		if msg, ok := e["error"]; ok {
			return fmt.Errorf("%s", msg)
		}
		return fmt.Errorf("login failed (HTTP %d)", resp.StatusCode)
	}
	// Store the session cookie for future requests (not strictly needed for
	// CLI since we use the gob port for vault ops, but kept for completeness).
	for _, cookie := range resp.Cookies() {
		if cookie.Name == "vault_session" {
			c.sessionCookie = cookie
			break
		}
	}
	return nil
}

// Vault operations via HTTP

func (c *httpClient) list() ([]string, error) {
	resp, data, err := c.get("/vault/list")
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		var e map[string]string
		json.Unmarshal(data, &e)
		if msg, ok := e["error"]; ok {
			return nil, fmt.Errorf("%s", msg)
		}
		return nil, fmt.Errorf("list failed (HTTP %d)", resp.StatusCode)
	}
	var result struct {
		Sites []string `json:"sites"`
	}
	if err := json.Unmarshal(data, &result); err != nil {
		return nil, err
	}
	return result.Sites, nil
}

func (c *httpClient) getEntry(site string) (map[string]string, error) {
	resp, data, err := c.get("/vault/get?site=" + url.QueryEscape(strings.TrimSpace(site)))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		var e map[string]string
		json.Unmarshal(data, &e)
		if msg, ok := e["error"]; ok {
			return nil, fmt.Errorf("%s", msg)
		}
		return nil, fmt.Errorf("get failed (HTTP %d)", resp.StatusCode)
	}
	var result map[string]string
	if err := json.Unmarshal(data, &result); err != nil {
		return nil, err
	}
	return result, nil
}

func (c *httpClient) save(site, username, password string) error {
	resp, data, err := c.post("/vault/save", map[string]string{
		"site":     site,
		"username": username,
		"password": password,
	})
	if err != nil {
		return err
	}
	if resp.StatusCode != http.StatusOK {
		var e map[string]string
		json.Unmarshal(data, &e)
		if msg, ok := e["error"]; ok {
			return fmt.Errorf("%s", msg)
		}
		return fmt.Errorf("save failed (HTTP %d)", resp.StatusCode)
	}
	return nil
}

func (c *httpClient) deleteEntry(site string) error {
	resp, data, err := c.delete("/vault/delete?site=" + url.QueryEscape(strings.TrimSpace(site)))
	if err != nil {
		return err
	}
	if resp.StatusCode != http.StatusOK {
		var e map[string]string
		json.Unmarshal(data, &e)
		if msg, ok := e["error"]; ok {
			return fmt.Errorf("%s", msg)
		}
		return fmt.Errorf("delete failed (HTTP %d)", resp.StatusCode)
	}
	return nil
}

func main() {
	masterAddr := flag.String("master", "localhost:9000", "Master gob address (host:port)")
	masterHTTP := flag.String("http", "", "Master HTTPS address for auth (host:port). Defaults to master host on port 8443")
	certFile := flag.String("cert", "certs/client-cert.pem", "TLS cert")
	keyFile := flag.String("key", "certs/client-key.pem", "TLS key")
	caFile := flag.String("ca", "certs/ca-cert.pem", "CA cert")
	flag.Parse()

	// Derive the HTTP address from the master gob address if not explicitly set.
	// e.g. "34.1.2.3:9000" → "34.1.2.3:8443"
	if *masterHTTP == "" {
		host := (*masterAddr)[:strings.LastIndex(*masterAddr, ":")]
		*masterHTTP = host + ":8443"
	}

	tlsCfg, err := appCrypto.LoadTLSConfig(*certFile, *keyFile, *caFile, false)
	if err != nil {
		log.Fatalf("TLS: %v", err)
	}

	authAPI := newHTTPClient(*masterHTTP, tlsCfg)

	scanner := bufio.NewScanner(os.Stdin)
	fmt.Println("=== Distributed Password Manager ===")
	fmt.Println("Commands: register, login, exit")

	var loggedInUser string

	for {
		if loggedInUser != "" {
			fmt.Printf("[%s] > ", loggedInUser)
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

			// Client-side length check mirrors the server-side check in auth.go
			// so the user gets immediate feedback without a round-trip.
			if len(password) < 8 {
				fmt.Println("Error: password must be at least 8 characters")
				continue
			}

			if err := authAPI.register(username, password); err != nil {
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

			// Verify credentials against the master's shared user store via HTTP.
			if err := authAPI.login(username, password); err != nil {
				fmt.Println("Login failed:", err)
				continue
			}

			loggedInUser = username
			fmt.Println("Logged in. Commands: save, get, list, delete, logout")

		case "save":
			if loggedInUser == "" {
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
			err := authAPI.save(site, user, pass)
			if err != nil {
				fmt.Println("Error:", err)
			} else {
				fmt.Println("Saved.")
			}

		case "get":
			if loggedInUser == "" {
				fmt.Println("Please login first.")
				continue
			}
			var site string
			if len(parts) > 1 {
				// Site name provided on command line: get github UI
				site = strings.TrimSpace(strings.TrimPrefix(line, "get"))
			} else {
				// Prompt for site
				fmt.Print("Site: ")
				scanner.Scan()
				site = strings.TrimSpace(scanner.Text())
			}
			entry, err := authAPI.getEntry(site)
			if err != nil {
				fmt.Println("Error:", err)
			} else {
				fmt.Printf("  Site:     %s\n", entry["site"])
				fmt.Printf("  Username: %s\n", entry["username"])
				fmt.Printf("  Password: %s\n", entry["password"])
			}

		case "list":
			if loggedInUser == "" {
				fmt.Println("Please login first.")
				continue
			}
			sites, err := authAPI.list()
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
			if loggedInUser == "" {
				fmt.Println("Please login first.")
				continue
			}
			var site string
			if len(parts) > 1 {
				// Site name provided on command line: delete github UI
				site = strings.TrimSpace(strings.TrimPrefix(line, "delete"))
			} else {
				// Prompt for site
				fmt.Print("Site: ")
				scanner.Scan()
				site = strings.TrimSpace(scanner.Text())
			}
			if err := authAPI.deleteEntry(site); err != nil {
				fmt.Println("Error:", err)
			} else {
				fmt.Println("Deleted.")
			}

		case "logout":
			loggedInUser = ""
			fmt.Println("Logged out.")

		case "exit", "quit":
			fmt.Println("Bye.")
			return

		default:
			fmt.Println("Unknown command:", parts[0])
			if loggedInUser != "" {
				fmt.Println("Commands: save, get, list, delete, logout, exit")
			} else {
				fmt.Println("Commands: register, login, exit")
			}
		}
	}
}

// getSaltFromLoginResponse calls the master HTTP login endpoint and extracts
// the salt from the response so the CLI can derive the vault key locally.
// This requires pkg/master/http.go handleLogin to include "salt" in its
// JSON response — see that file for the matching change.
func (c *httpClient) getSaltFromLoginResponse(username, password string) ([]byte, error) {
	resp, data, err := c.post("/auth/login", map[string]string{
		"username": username,
		"password": password,
	})
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("login failed (HTTP %d)", resp.StatusCode)
	}
	var body struct {
		Salt []byte `json:"salt"`
	}
	if err := json.Unmarshal(data, &body); err != nil {
		return nil, fmt.Errorf("could not parse login response: %w", err)
	}
	if len(body.Salt) == 0 {
		return nil, fmt.Errorf("master did not return salt in login response")
	}
	return body.Salt, nil
}
