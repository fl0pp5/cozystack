package imageoverrides

import (
	"fmt"
	"math/rand"
	"os"
	"strings"
	"testing"

	"github.com/fluxcd/pkg/apis/kustomize"
	"sigs.k8s.io/kustomize/api/krusty"
	kustypes "sigs.k8s.io/kustomize/api/types"
	"sigs.k8s.io/kustomize/kyaml/filesys"
	"sigs.k8s.io/yaml"
)

// parityFile is shared with the cozy-lib helper tests: every implementation
// of the rules must turn each ref into want.
const parityFile = "testdata/parity.yaml"

type parityCase struct {
	Name  string  `json:"name"`
	Ref   string  `json:"ref"`
	Table []Entry `json:"table"`
	Want  string  `json:"want"`
}

type parityFixture struct {
	Cases []parityCase `json:"cases"`
}

// krustyApply runs the table through the kustomize build helm-controller
// performs for a post-renderer, on a Pod carrying ref.
func krustyApply(t *testing.T, ref string, images []kustomize.Image) string {
	t.Helper()
	fs := filesys.MakeFsInMemory()
	pod := fmt.Sprintf("apiVersion: v1\nkind: Pod\nmetadata: {name: p}\nspec:\n  containers:\n  - {name: c, image: %q}\n", ref)
	imgs := make([]kustypes.Image, len(images))
	for i, img := range images {
		imgs[i] = kustypes.Image{Name: img.Name, NewName: img.NewName, NewTag: img.NewTag, Digest: img.Digest}
	}
	k, err := yaml.Marshal(map[string]any{"resources": []string{"pod.yaml"}, "images": imgs})
	if err != nil {
		t.Fatal(err)
	}
	if err := fs.WriteFile("/k/pod.yaml", []byte(pod)); err != nil {
		t.Fatal(err)
	}
	if err := fs.WriteFile("/k/kustomization.yaml", k); err != nil {
		t.Fatal(err)
	}
	opts := &krusty.Options{LoadRestrictions: kustypes.LoadRestrictionsNone, PluginConfig: kustypes.DisabledPluginConfig()}
	rm, err := krusty.MakeKustomizer(opts).Run(fs, "/k")
	if err != nil {
		t.Fatalf("krusty on %s: %v", ref, err)
	}
	out, err := rm.Resources()[0].GetFieldValue("spec.containers.0.image")
	if err != nil {
		t.Fatal(err)
	}
	return out.(string)
}

func TestParity(t *testing.T) {
	if os.Getenv("UPDATE_PARITY") != "" {
		writeParityFixture(t)
	}
	raw, err := os.ReadFile(parityFile)
	if err != nil {
		t.Fatal(err)
	}
	var fx parityFixture
	if err := yaml.UnmarshalStrict(raw, &fx); err != nil {
		t.Fatal(err)
	}
	if len(fx.Cases) == 0 {
		t.Fatal("no cases")
	}
	for _, c := range fx.Cases {
		images, err := Compile(c.Table)
		if err != nil {
			t.Errorf("%s: table rejected: %v", c.Name, err)
			continue
		}
		if got := krustyApply(t, c.Ref, images); got != c.Want {
			t.Errorf("%s: krusty gives %s, fixture wants %s (UPDATE_PARITY=1 regenerates)", c.Name, got, c.Want)
		}
		if got := Apply(c.Ref, images); got != c.Want {
			t.Errorf("%s: Apply gives %s, want %s\n  ref %s\n  table %+v", c.Name, got, c.Want, c.Ref, images)
		}
	}
}

// writeParityFixture keeps the hand-written cases, regenerates the generated
// ones from a fixed seed, and takes every want from krusty.
func writeParityFixture(t *testing.T) {
	var fx parityFixture
	if raw, err := os.ReadFile(parityFile); err == nil {
		if err := yaml.UnmarshalStrict(raw, &fx); err != nil {
			t.Fatal(err)
		}
	}
	var cases []parityCase
	for _, c := range fx.Cases {
		if !strings.HasPrefix(c.Name, "generated ") {
			cases = append(cases, c)
		}
	}
	cases = append(cases, generateParityCases(400)...)
	for i := range cases {
		images, err := Compile(cases[i].Table)
		if err != nil {
			t.Fatalf("%s: %v", cases[i].Name, err)
		}
		cases[i].Want = krustyApply(t, cases[i].Ref, images)
	}
	out, err := yaml.Marshal(parityFixture{Cases: cases})
	if err != nil {
		t.Fatal(err)
	}
	header := "# Shared by every implementation of the image override rules: pkg/imageoverrides\n" +
		"# (Apply, and kustomize through krusty) and the cozy-lib helpers. Regenerate the\n" +
		"# generated cases and every want with: UPDATE_PARITY=1 go test ./pkg/imageoverrides -run TestParity\n"
	if err := os.WriteFile(parityFile, append([]byte(header), out...), 0o644); err != nil {
		t.Fatal(err)
	}
}

func generateParityCases(n int) []parityCase {
	r := rand.New(rand.NewSource(1))
	names := []string{"redis", "docker.io/library/redis", "ghcr.io/cloudnative-pg/postgresql", "localhost:5000/x/y",
		"registry.example.org:5000/a", "foundationdb/fdb-kubernetes-monitor", "quay.io/strimzi/kafka"}
	tags := []string{"", "1.0", "7.3.63", "7.4.1", "16.11", "v1.2.3-rc.1", "0.45.1-kafka-3.9.0"}
	d1, d2, d3 := "sha256:"+strings.Repeat("a", 64), "sha256:"+strings.Repeat("b", 64), "sha256:"+strings.Repeat("c", 64)
	digests := []string{"", d1, d2}
	newNames := []string{"", "registry.os/x", "registry.os/postgresql", "ghcr.io/cloudnative-pg/postgresql", "redis"}
	pick := func(s []string) string { return s[r.Intn(len(s))] }

	var out []parityCase
	for i := 0; len(out) < n; i++ {
		name, tag, digest := pick(names), pick(tags), pick(digests)
		ref := name
		if tag != "" {
			ref += ":" + tag
		}
		if digest != "" {
			ref += "@" + digest
		}
		var table []Entry
		for j := 0; j <= r.Intn(3); j++ {
			e := Entry{Image: kustomize.Image{Name: name}}
			if r.Intn(10) >= 7 {
				e.Name = pick(names)
			}
			switch m := r.Intn(20); {
			case m < 5:
				e.Match = &Match{Tag: pick(tags[1:])}
			case m < 8:
				e.Match = &Match{Digest: pick(digests[1:])}
			}
			for e.NewName == "" && e.NewTag == "" && e.Digest == "" {
				e.NewName = pick(newNames)
				e.NewTag = pick([]string{"", "", "9.9", "7.3.63-os1"})
				e.Digest = pick([]string{"", "", d3})
			}
			table = append(table, e)
		}
		if Validate(table) != nil {
			continue
		}
		out = append(out, parityCase{Name: fmt.Sprintf("generated %d", len(out)), Ref: ref, Table: table})
	}
	return out
}
