export NAME=gpu-operator
export NAMESPACE=cozy-$(NAME)

include ../../../hack/common-envs.mk
include ../../../hack/package.mk

# hack/helm-unit-tests.sh discovers work by probing for this target, so a
# package without one is skipped in silence however many suites sit under
# tests/. Phony because hack/package.mk's .PHONY line lists only the targets
# that file defines, so a path named `test` here would make the target up to
# date and skip the recipe.
.PHONY: test
test:
	helm unittest .

update:
	rm -rf charts
	helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
	helm repo update nvidia
	helm pull nvidia/gpu-operator --untar --untardir charts --version v26.3.1
	# The operator starts every GPU component from a repository/image/version
	# triple in its ClusterPolicy (and NVIDIADriver), out of the
	# post-renderer's reach, so the platform's image override table reaches
	# them through this patch, which renders the two templates with a copy of
	# the values whose triples templates/_cozystack_image_values.tpl rewrites.
	patch --no-backup-if-mismatch -p4 < patches/image-overrides.diff
	# cozy-lib is a link into the tree rather than a vendored chart, and the
	# rm -rf above took it with the rest of charts/.
	ln -sfn ../../../library/cozy-lib charts/cozy-lib
