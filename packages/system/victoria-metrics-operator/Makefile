export NAME=victoria-metrics-operator
export NAMESPACE=cozy-$(NAME)

include ../../../hack/common-envs.mk
include ../../../hack/package.mk

update:
	rm -rf charts
	# VictoriaMetrics operator
	helm repo add vm https://victoriametrics.github.io/helm-charts/
	helm repo update vm
	helm pull vm/victoria-metrics-operator --untar --untardir charts
	patch --no-backup-if-mismatch -p4 < patches/disable-ca-key-rotation.patch
	# The images the operator runs for a VMAgent that names none. The
	# monitoring-agents chart applies the image override table to them, so
	# they must follow the operator: the vmagent version is compiled into it.
	# sed rather than yq -i, which would reflow the rest of that values.yaml.
	@app=$$(yq '.appVersion' charts/victoria-metrics-operator/Chart.yaml) && \
	  metrics=$$(curl -sSfL "https://raw.githubusercontent.com/VictoriaMetrics/operator/$$app/internal/config/config.go" | sed -n 's/.*"VM_METRICS_VERSION": *"\([^"]*\)".*/\1/p') && \
	  { [ -n "$$metrics" ] || { echo "ERROR: no VM_METRICS_VERSION in operator $$app" >&2; exit 1; }; } && \
	  vmagent="victoriametrics/vmagent:$$metrics" && reloader="victoriametrics/operator:config-reloader-$$app" && \
	  vmagent="$$vmagent@$$(skopeo inspect --format '{{.Digest}}' docker://docker.io/$$vmagent)" && \
	  reloader="$$reloader@$$(skopeo inspect --format '{{.Digest}}' docker://docker.io/$$reloader)" && \
	  $(SED_INPLACE) -e "s|^  image: victoriametrics/vmagent:.*|  image: $$vmagent|" \
	    -e "s|^  configReloaderImage: victoriametrics/operator:.*|  configReloaderImage: $$reloader|" ../monitoring-agents/values.yaml && \
	  [ "$$(yq '.vmagent.image' ../monitoring-agents/values.yaml)" = "$$vmagent" ] && \
	  [ "$$(yq '.vmagent.configReloaderImage' ../monitoring-agents/values.yaml)" = "$$reloader" ] || \
	  { echo "ERROR: vmagent images in monitoring-agents/values.yaml were not re-pinned; their shape no longer matches the update recipe" >&2; exit 1; }
