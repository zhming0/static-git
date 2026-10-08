package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// lfsServer is a minimal Git LFS server: the batch API with the "basic"
// transfer, enough for git-lfs to download and upload objects. Objects of
// every repository share one directory, named by their sha256.
//
//	POST <repo>.git/info/lfs/objects/batch
//	GET  <repo>.git/info/lfs/objects/<oid>
//	PUT  <repo>.git/info/lfs/objects/<oid>
type lfsServer struct {
	dir string
}

const lfsPath = "/info/lfs/objects"

var oidRE = regexp.MustCompile(`^[0-9a-f]{64}$`)

// withLFS sends LFS requests to lfs and the rest to next. prefix is the part
// of the path a parent handler stripped, needed to build absolute links.
func withLFS(lfs *lfsServer, prefix string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		i := strings.Index(r.URL.Path, lfsPath)
		if i < 0 {
			next.ServeHTTP(w, r)
			return
		}
		base := r.URL.Path[:i+len(lfsPath)]
		rest := r.URL.Path[len(base):]
		switch {
		case rest == "/batch" && r.Method == http.MethodPost:
			lfs.batch(w, r, "https://"+r.Host+prefix+base)
		case strings.HasPrefix(rest, "/") && oidRE.MatchString(rest[1:]) && r.Method == http.MethodGet:
			http.ServeFile(w, r, filepath.Join(lfs.dir, rest[1:]))
		case strings.HasPrefix(rest, "/") && oidRE.MatchString(rest[1:]) && r.Method == http.MethodPut:
			lfs.put(w, r, rest[1:])
		default:
			http.NotFound(w, r)
		}
	})
}

type lfsObject struct {
	OID     string               `json:"oid"`
	Size    int64                `json:"size"`
	Actions map[string]lfsAction `json:"actions,omitempty"`
	Error   *lfsError            `json:"error,omitempty"`
	Auth    bool                 `json:"authenticated,omitempty"`
}

type lfsAction struct {
	Href   string            `json:"href"`
	Header map[string]string `json:"header,omitempty"`
}

type lfsError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func (s *lfsServer) batch(w http.ResponseWriter, r *http.Request, objectsURL string) {
	var req struct {
		Operation string      `json:"operation"`
		Objects   []lfsObject `json:"objects"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	// Object links carry the batch request's credentials, so they work under
	// /auth/ without asking for them again.
	header := map[string]string{}
	if a := r.Header.Get("Authorization"); a != "" {
		header["Authorization"] = a
	}

	out := make([]lfsObject, 0, len(req.Objects))
	for _, o := range req.Objects {
		res := lfsObject{OID: o.OID, Size: o.Size, Auth: true}
		if !oidRE.MatchString(o.OID) {
			res.Error = &lfsError{Code: 422, Message: "bad oid"}
			out = append(out, res)
			continue
		}
		_, err := os.Stat(filepath.Join(s.dir, o.OID))
		exists := err == nil
		action := lfsAction{Href: objectsURL + "/" + o.OID, Header: header}
		switch {
		case req.Operation == "download" && exists:
			res.Actions = map[string]lfsAction{"download": action}
		case req.Operation == "download":
			res.Error = &lfsError{Code: 404, Message: "not found"}
		case req.Operation == "upload" && !exists:
			res.Actions = map[string]lfsAction{"upload": action}
		}
		out = append(out, res)
	}

	w.Header().Set("Content-Type", "application/vnd.git-lfs+json")
	_ = json.NewEncoder(w).Encode(map[string]any{"transfer": "basic", "objects": out})
}

// put stores an uploaded object if its content matches its oid.
func (s *lfsServer) put(w http.ResponseWriter, r *http.Request, oid string) {
	tmp, err := os.CreateTemp(s.dir, "upload-")
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer os.Remove(tmp.Name())
	h := sha256.New()
	_, err = io.Copy(io.MultiWriter(tmp, h), r.Body)
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if hex.EncodeToString(h.Sum(nil)) != oid {
		http.Error(w, "content does not match oid", http.StatusUnprocessableEntity)
		return
	}
	if err := os.Rename(tmp.Name(), filepath.Join(s.dir, oid)); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusOK)
}
