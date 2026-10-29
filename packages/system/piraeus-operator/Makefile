export NAME=piraeus-operator
export NAMESPACE=cozy-linstor

include ../../../hack/package.mk

.PHONY: test
test:
	helm unittest .

update:
	rm -rf charts config
	tag=$$(git ls-remote --tags --sort="v:refname" https://github.com/piraeusdatastore/piraeus-operator  | awk -F'[/^]' 'END{print $$3}') && \
	curl -sSL https://github.com/piraeusdatastore/piraeus-operator/archive/refs/tags/$${tag}.tar.gz | \
	tar xzvf - --strip 1 piraeus-operator-$${tag#*v}/charts piraeus-operator-$${tag#*v}/config/manager
	mv charts/piraeus/templates/crds.yaml ../piraeus-operator-crds/templates/crds.yaml
	# The operator takes a RELATED_IMAGE_<component>_<image> env as the whole
	# reference of an image it would otherwise build from its image-config,
	# so the platform's image override table reaches those images through the
	# env patches/image-overrides.diff adds. The defaults are the files
	# upstream generates image-config from, kept beside the chart for the
	# helper in templates/_cozystack_image_env.tpl to read.
	mkdir charts/piraeus/cozystack-image-config
	mv config/manager/0_*_images.yaml charts/piraeus/cozystack-image-config/
	rm -rf config
	patch --no-backup-if-mismatch -p4 < patches/image-overrides.diff
	# cozy-lib is a link into the tree rather than a vendored chart, and the
	# rm -rf above took it with the rest of charts/.
	ln -sfn ../../../library/cozy-lib charts/cozy-lib
