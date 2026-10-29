package imageoverrides

import (
	"fmt"
	"regexp"
	"strings"

	"github.com/fluxcd/pkg/apis/kustomize"
)

// Apply rewrites one image reference with the table the way the kustomize
// images transformer in helm-controller does: entries in order, each against
// the result of the ones before it. It reproduces kustomize rather than
// calling it so that code outside a HelmRelease (validation, migrations) can
// apply the same rules; the parity tests hold the two together.
func Apply(ref string, images []kustomize.Image) string {
	for _, img := range images {
		if !matches(ref, img.Name) {
			continue
		}
		name, tag, digest := Split(ref)
		if img.NewName != "" {
			name = img.NewName
		}
		switch {
		case img.NewTag != "" && img.Digest != "":
			tag, digest = img.NewTag, img.Digest
		case img.NewTag != "":
			tag, digest = img.NewTag, ""
		case img.Digest != "":
			tag, digest = "", img.Digest
		}
		ref = name
		if tag != "" {
			ref += ":" + tag
		}
		if digest != "" {
			ref += "@" + digest
		}
	}
	return ref
}

// Idempotent reports the first reference the table rewrites again when
// applied to its own result. A reference can pass through two routes, a
// template helper and then the post-renderer, so a table that is not
// idempotent renders differently depending on the route.
func Idempotent(refs []string, images []kustomize.Image) error {
	for _, ref := range refs {
		once := Apply(ref, images)
		if twice := Apply(once, images); twice != once {
			return fmt.Errorf("%s is not idempotent on %s: %s, then %s", ClusterKey, ref, once, twice)
		}
	}
	return nil
}

// matches is sigs.k8s.io/kustomize/api/internal/image.IsImageMatched: the
// name is used as a regular expression, unescaped.
func matches(ref, name string) bool {
	re, err := regexp.Compile("^" + name + `(:[a-zA-Z0-9_.{}-]*)?(@sha256:[a-zA-Z0-9_.{}-]*)?$`)
	return err == nil && re.MatchString(ref)
}

// Split is sigs.k8s.io/kustomize/api/internal/image.Split: the first path
// component may carry a port, so ':' and '@' are looked for after it.
func Split(ref string) (name, tag, digest string) {
	search := ref
	slash := strings.Index(ref, "/")
	if slash > 0 {
		search = ref[slash:]
	} else {
		slash = 0
	}
	id := strings.Index(search, "@")
	ic := strings.Index(search, ":")
	switch {
	case ic < 0 && id < 0:
		return ref, "", ""
	case id >= 0 && (id < ic || ic < 0):
		id += slash
		return ref[:id], "", ref[id+1:]
	case id >= 0 && ic >= 0:
		id += slash
		ic += slash
		return ref[:ic], ref[ic+1 : id], ref[id+1:]
	default:
		ic += slash
		return ref[:ic], ref[ic+1:], ""
	}
}
