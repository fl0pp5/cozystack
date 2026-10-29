// SPDX-License-Identifier: Apache-2.0
package backupcontroller

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/fluxcd/pkg/apis/kustomize"
	corev1 "k8s.io/api/core/v1"
	apiequality "k8s.io/apimachinery/pkg/api/equality"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
	clientfake "sigs.k8s.io/controller-runtime/pkg/client/fake"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"

	"github.com/cozystack/cozystack/internal/backupcontroller/foundationdbtypes"
	"github.com/cozystack/cozystack/pkg/imageoverrides"
)

const testDigest = "sha256:1111111111111111111111111111111111111111111111111111111111111111"

func TestFoundationDBImageConfigs(t *testing.T) {
	for _, tc := range []struct {
		name    string
		images  []kustomize.Image
		want    []foundationdbtypes.ImageConfig
		wantErr string
	}{
		{name: "no table leaves the image to the operator"},
		{
			name:   "an entry for another image leaves it too",
			images: []kustomize.Image{{Name: "foundationdb/foundationdb", NewName: "registry.example.org/os/foundationdb"}},
		},
		{
			name:   "an entry for another version leaves it too",
			images: []kustomize.Image{{Name: "foundationdb/fdb-kubernetes-monitor:7.4.1", NewName: "registry.example.org/os/fdb-monitor"}},
		},
		{
			name:   "a rename keeps the version as the tag",
			images: []kustomize.Image{{Name: "foundationdb/fdb-kubernetes-monitor", NewName: "registry.example.org/os/fdb-monitor"}},
			want:   []foundationdbtypes.ImageConfig{{Version: "7.3.63", BaseImage: "registry.example.org/os/fdb-monitor", Tag: "7.3.63"}},
		},
		{
			name:   "a tag and a digest go into the tag",
			images: []kustomize.Image{{Name: "foundationdb/fdb-kubernetes-monitor:7.3.63", NewTag: "7.3.63-os1", Digest: testDigest}},
			want:   []foundationdbtypes.ImageConfig{{Version: "7.3.63", BaseImage: "foundationdb/fdb-kubernetes-monitor", Tag: "7.3.63-os1@" + testDigest}},
		},
		{
			name:    "a digest without a tag cannot be expressed",
			images:  []kustomize.Image{{Name: "foundationdb/fdb-kubernetes-monitor", Digest: testDigest}},
			wantErr: "which has no tag",
		},
		{
			name:    "a tag longer than the operator stores is refused",
			images:  []kustomize.Image{{Name: "foundationdb/fdb-kubernetes-monitor", NewTag: strings.Repeat("t", 30), Digest: testDigest}},
			wantErr: "longer than the 100 characters",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := foundationDBImageConfigs(foundationDBUnifiedImage, "7.3.63", tc.images)
			if tc.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
					t.Fatalf("want error containing %q, got %v", tc.wantErr, err)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if !apiequality.Semantic.DeepEqual(got, tc.want) {
				t.Errorf("got %#v, want %#v", got, tc.want)
			}
		})
	}
}

func cozystackValuesSecret(values string) *corev1.Secret {
	return &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Namespace: imageoverrides.DefaultSecret.Namespace, Name: imageoverrides.DefaultSecret.Name},
		Data:       map[string][]byte{"values.yaml": []byte(values)},
	}
}

func TestEnsureFoundationDBBackup_ImageOverrides(t *testing.T) {
	for _, tc := range []struct {
		name   string
		secret *corev1.Secret
		want   *foundationdbtypes.ContainerOverrides
	}{
		{name: "without the values Secret the operator picks the image"},
		{name: "without a table the operator picks the image", secret: cozystackValuesSecret("_cluster: {}\n")},
		{
			name: "the table names the agents' image for the cluster's version",
			secret: cozystackValuesSecret(`_cluster:
  image-overrides:
    - name: foundationdb/fdb-kubernetes-monitor
      match: {tag: 7.3.63}
      newName: registry.example.org/os/fdb-monitor
`),
			want: &foundationdbtypes.ContainerOverrides{ImageConfigs: []foundationdbtypes.ImageConfig{
				{Version: "7.3.63", BaseImage: "registry.example.org/os/fdb-monitor", Tag: "7.3.63"},
			}},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := newFoundationDBStrategyTestClient(t)
			if tc.secret != nil {
				if err := c.Create(context.Background(), tc.secret); err != nil {
					t.Fatalf("seed values Secret: %v", err)
				}
			}
			r := &BackupJobReconciler{Client: c, Scheme: c.Scheme()}
			job := newFoundationDBBackupJob("bj-1", "tenant")
			if err := c.Create(context.Background(), job); err != nil {
				t.Fatalf("seed BackupJob: %v", err)
			}
			got, err := r.ensureFoundationDBBackup(context.Background(), job, foundationdbClusterNameForApp("fdb-src"), "7.3.63", newRenderedFoundationDBTemplate())
			if err != nil {
				t.Fatalf("ensureFoundationDBBackup: %v", err)
			}
			if !apiequality.Semantic.DeepEqual(got.Spec.MainContainer, tc.want) {
				t.Errorf("mainContainer: got %#v, want %#v", got.Spec.MainContainer, tc.want)
			}
		})
	}
}

// A table the driver cannot read must not fail the BackupJob for good: the
// reconcile returns the error to be retried, and no backup is created on an
// image the table may have moved.
func TestEnsureFoundationDBBackup_UnreadableTableIsRetried(t *testing.T) {
	base := newFoundationDBStrategyTestClient(t)
	c := clientfake.NewClientBuilder().WithScheme(base.Scheme()).WithInterceptorFuncs(interceptor.Funcs{
		Get: func(ctx context.Context, cl client.WithWatch, key client.ObjectKey, obj client.Object, opts ...client.GetOption) error {
			if key == imageoverrides.DefaultSecret {
				return errors.New("apiserver unavailable")
			}
			return cl.Get(ctx, key, obj, opts...)
		},
	}).Build()
	r := &BackupJobReconciler{Client: c, Scheme: c.Scheme()}
	job := newFoundationDBBackupJob("bj-1", "tenant")
	if err := c.Create(context.Background(), job); err != nil {
		t.Fatalf("seed BackupJob: %v", err)
	}
	_, err := r.ensureFoundationDBBackup(context.Background(), job, foundationdbClusterNameForApp("fdb-src"), "7.3.63", newRenderedFoundationDBTemplate())
	if !errors.Is(err, errImageOverridesUnavailable) {
		t.Fatalf("want errImageOverridesUnavailable, got %v", err)
	}
	list := &foundationdbtypes.FoundationDBBackupList{}
	if err := c.List(context.Background(), list); err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(list.Items) != 0 {
		t.Errorf("created %d FoundationDBBackup(s) without the table", len(list.Items))
	}
}
