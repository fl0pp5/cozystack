export NAME=mariadb-operator
export NAMESPACE=cozy-$(NAME)

include ../../../hack/package.mk

update:
	rm -rf charts
	helm repo add mariadb-operator https://mariadb-operator.github.io/mariadb-operator
	helm repo update mariadb-operator
	helm pull mariadb-operator/mariadb-operator --untar --untardir charts
	# The operator copies these references into the MariaDB and MaxScale
	# resources it creates, so the platform's image override table must reach
	# them here, through the cozy-lib the wrapper vendors; the post-renderer
	# sees only the operator's own container.
	patch --no-backup-if-mismatch -p4 < patches/image-overrides.diff
	# cozy-lib is a link into the tree rather than a vendored chart, and the
	# rm -rf above took it with the rest of charts/.
	ln -sfn ../../../library/cozy-lib charts/cozy-lib

test:
	helm unittest .
