// Command githttpd serves the repositories under /srv/git over HTTPS with
// git-http-backend, for the matrix test.
//
//	/<repo>.git        anonymous
//	/auth/<repo>.git   needs HTTP basic auth (AUTH_USER, AUTH_PASS)
//
// Each also serves a Git LFS server at <repo>.git/info/lfs (see lfs.go).
//
// Every request is logged to stdout, so the test can check what the client
// sent.
package main

import (
	"crypto/subtle"
	"log"
	"net/http"
	"net/http/cgi"
	"os"
)

func main() {
	backend := &cgi.Handler{
		Path: "/usr/libexec/git-core/git-http-backend",
		Env:  []string{"GIT_PROJECT_ROOT=/srv/git", "GIT_HTTP_EXPORT_ALL=1"},
	}
	user, pass := os.Getenv("AUTH_USER"), os.Getenv("AUTH_PASS")

	lfs := &lfsServer{dir: "/srv/lfs"}
	mux := http.NewServeMux()
	mux.Handle("/auth/", http.StripPrefix("/auth", basicAuth(user, pass, withLFS(lfs, "/auth", backend))))
	mux.Handle("/", withLFS(lfs, "", backend))

	log.SetOutput(os.Stdout)
	log.Fatal(http.ListenAndServeTLS(":443",
		"/etc/gitserver/server.crt", "/etc/gitserver/server.key", logRequests(mux)))
}

func basicAuth(user, pass string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		u, p, ok := r.BasicAuth()
		if !ok || subtle.ConstantTimeCompare([]byte(u+":"+p), []byte(user+":"+pass)) != 1 {
			w.Header().Set("WWW-Authenticate", `Basic realm="git"`)
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		log.Printf("%s %s %s %s ua=%q", r.RemoteAddr, r.Proto, r.Method, r.URL, r.UserAgent())
		next.ServeHTTP(w, r)
	})
}
