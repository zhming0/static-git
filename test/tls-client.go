// A standalone Go TLS consumer for the system CA installation matrix check.
// It deliberately runs outside the git launcher and uses no CA overrides.
package main

import (
	"log"
	"net/http"
	"os"
	"time"
)

func main() {
	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Get(os.Args[1])
	if err != nil {
		log.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		log.Fatalf("HTTP status: %s", resp.Status)
	}
}
