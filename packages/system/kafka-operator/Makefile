export NAME=kafka-operator
export NAMESPACE=cozy-$(NAME)

include ../../../hack/package.mk

test:
	helm unittest .

update:
	rm -rf charts
	helm pull oci://quay.io/strimzi-helm/strimzi-kafka-operator --untar --untardir charts --version 0.45.1-rc1
	# Strimzi passes the images it deploys, each Kafka version of an operand
	# separately, from operator env the chart renders through strimzi.image,
	# so the platform's image override table reaches them through that one
	# template, which this patch passes through the cozy-lib the wrapper
	# vendors; the post-renderer sees only the operator's own container.
	patch --no-backup-if-mismatch -p4 < patches/image-overrides.diff
	# cozy-lib is a link into the tree rather than a vendored chart, and the
	# rm -rf above took it with the rest of charts/.
	ln -sfn ../../../library/cozy-lib charts/cozy-lib
