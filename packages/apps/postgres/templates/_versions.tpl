{{- define "postgres.versionMap" }}
{{- $versionMap := .Files.Get "files/versions.yaml" | fromYaml }}
{{- if not (hasKey $versionMap .Values.version) }}
    {{- printf `PostgreSQL version %s is not supported, allowed versions are %s` $.Values.version (keys $versionMap) | fail }}
{{- end }}
{{- index $versionMap .Values.version }}
{{- end }}

{{- define "postgres.postgisVersionMap" }}
{{- $versionMap := .Files.Get "files/postgis-versions.yaml" | fromYaml }}
{{- if not (hasKey $versionMap .Values.version) }}
    {{- printf `PostgreSQL version %s is not supported by the postgis flavor, allowed versions are %s` $.Values.version (keys $versionMap | sortAlpha) | fail }}
{{- end }}
{{- index $versionMap .Values.version }}
{{- end }}

{{/*
  Single source for the operand image: the init Job runs psql against the
  Cluster, so both must resolve the same image. CNPG reads the image from the
  Cluster, out of the post-renderer's reach, so the override table is applied
  here.
*/}}
{{- define "postgres.imageName" -}}
{{- include "cozy-lib.image" (list (include "postgres.upstreamImageName" .) .) -}}
{{- end -}}

{{- define "postgres.upstreamImageName" -}}
{{- if eq (default "postgresql" .Values.flavor) "postgis" -}}
ghcr.io/cloudnative-pg/postgis:{{ include "postgres.postgisVersionMap" . | trim }}
{{- else -}}
ghcr.io/cloudnative-pg/postgresql:{{ include "postgres.versionMap" . | trim | trimPrefix "v" }}
{{- end -}}
{{- end -}}

{{/*
  The flavor is fixed at bootstrap. The two image families are built on
  different Debian releases, so moving a live cluster from one to the other
  swaps glibc under an initialised data directory and silently invalidates
  every index on collatable text; the postgis-to-postgresql direction also
  drops the shared libraries behind every PostGIS object. CNPG would roll
  either change out as an ordinary image update, so refuse it here, before
  the Cluster is patched. Only the image name is compared: a minor bump or
  a registry mirror rewriting the host must keep passing.

  A physical recovery carries the same data directory across, so it is held
  to the same rule. With no live Cluster of its own yet, the release is
  checked against its recovery source while that Cluster still exists; once
  the source is gone the chart has nothing to compare against, and the
  backup-controller's RestoreJob, which records the flavor on every Backup,
  is the path that enforces it.
*/}}
{{- define "postgres.flavorGuard" -}}
{{- $wantName := default "postgresql" .Values.flavor -}}
{{- $live := lookup "postgresql.cnpg.io/v1" "Cluster" .Release.Namespace .Release.Name -}}
{{- if and $live $live.spec $live.spec.imageName -}}
{{- $liveName := include "postgres.clusterFlavor" (list $live .) -}}
{{- if ne $liveName $wantName -}}
{{- fail (printf "postgres: flavor cannot change on an existing cluster (running %s, requested %s). The image families use different glibc versions, which would corrupt text indexes. Create a new Postgres with the wanted flavor and move the data with a logical dump (pg_dump / pg_restore); restoring a backup keeps the flavor it was taken from." $liveName $wantName) -}}
{{- end -}}
{{- else if and .Values.bootstrap.enabled .Values.bootstrap.oldName -}}
{{- $source := lookup "postgresql.cnpg.io/v1" "Cluster" .Release.Namespace .Values.bootstrap.oldName -}}
{{- if and $source $source.spec $source.spec.imageName -}}
{{- $sourceName := include "postgres.clusterFlavor" (list $source .) -}}
{{- if ne $sourceName $wantName -}}
{{- fail (printf "postgres: cannot recover a %s backup of %s into the %s flavor. A physical restore keeps the source's glibc and libraries, which would corrupt text indexes. Set flavor to match the source, or create the new Postgres empty and move the data with a logical dump (pg_dump / pg_restore)." $sourceName .Values.bootstrap.oldName $wantName) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
  The flavor a live Cluster runs. The image name tells it only under the
  upstream names; a Cluster whose image the override table renamed carries the
  flavor in an annotation (postgres.flavorAnnotation), so that changing or
  removing the table later is not read as a flavor change. The
  backup-controller reads the Cluster the same way.
*/}}
{{- define "postgres.clusterFlavor" -}}
{{- $cluster := index . 0 -}}
{{- with dig "metadata" "annotations" "postgres.cozystack.io/flavor" "" $cluster -}}
{{- . -}}
{{- else -}}
{{- include "postgres.flavorOf" (list $cluster.spec.imageName (index . 1)) -}}
{{- end -}}
{{- end -}}

{{/*
  The annotation recording the flavor, set only on a Cluster whose image the
  override table renamed: without a table the image name tells the flavor and
  the Cluster renders as it always has.
*/}}
{{- define "postgres.flavorAnnotation" -}}
{{- if ne (include "postgres.imageName" .) (include "postgres.upstreamImageName" .) -}}
postgres.cozystack.io/flavor: {{ default "postgresql" .Values.flavor }}
{{- end -}}
{{- end -}}

{{/*
  The flavor an image runs, by the last component of its name. The override
  table may rename either family, so a name the current table gives an
  upstream image counts as that image's flavor. Any other name is returned as
  it is and compares unequal.
*/}}
{{- define "postgres.flavorOf" -}}
{{- $ref := index . 0 -}}
{{- $ctx := index . 1 -}}
{{- $base := regexReplaceAll "[:@].*$" (last (splitList "/" $ref)) "" -}}
{{- $flavor := $base -}}
{{- range $upstream := list "postgresql" "postgis" -}}
{{-   $renamed := regexReplaceAll "[:@].*$" (last (splitList "/" (include "cozy-lib.imageName" (list (printf "ghcr.io/cloudnative-pg/%s" $upstream) $ctx)))) "" -}}
{{-   if or (eq $base $upstream) (eq $base $renamed) -}}
{{-     $flavor = $upstream -}}
{{-   end -}}
{{- end -}}
{{- $flavor -}}
{{- end -}}
