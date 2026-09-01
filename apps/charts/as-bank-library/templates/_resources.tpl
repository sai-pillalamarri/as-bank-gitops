{{- define "as-bank-library.labels" -}}
app: {{ .name | quote }}
version: {{ .workload.version | quote }}
environment: {{ .root.Values.global.environment | quote }}
team: {{ .root.Values.global.team | quote }}
cost-center: {{ .root.Values.global.costCenter | quote }}
{{- end }}

{{- define "as-bank-library.selectorLabels" -}}
app: {{ .name | quote }}
environment: {{ .root.Values.global.environment | quote }}
{{- end }}

{{- define "as-bank-library.serviceAccount" -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ .name }}
  namespace: {{ .root.Values.global.namespace }}
  labels:
    {{- include "as-bank-library.labels" . | nindent 4 }}
automountServiceAccountToken: false
{{- end }}

{{- define "as-bank-library.externalSecret" -}}
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: {{ .name }}-database
  namespace: {{ .root.Values.global.namespace }}
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
  labels:
    {{- include "as-bank-library.labels" . | nindent 4 }}
spec:
  refreshInterval: 1h

  secretStoreRef:
    kind: SecretStore
    name: aws-secrets-manager

  target:
    name: {{ .name }}-database
    creationPolicy: Owner

  data:
    - secretKey: DB_HOST
      remoteRef:
        key: {{ .workload.database.remoteSecret | quote }}
        property: host

    - secretKey: DB_PORT
      remoteRef:
        key: {{ .workload.database.remoteSecret | quote }}
        property: port

    - secretKey: DB_NAME
      remoteRef:
        key: {{ .workload.database.remoteSecret | quote }}
        property: database

    - secretKey: DB_USERNAME
      remoteRef:
        key: {{ .workload.database.remoteSecret | quote }}
        property: username

    - secretKey: DB_PASSWORD
      remoteRef:
        key: {{ .workload.database.remoteSecret | quote }}
        property: password
{{- end }}

{{- define "as-bank-library.runtimeConfig" -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .name }}-runtime-config
  namespace: {{ .root.Values.global.namespace }}
  labels:
    {{- include "as-bank-library.labels" . | nindent 4 }}
data:
  config.json: |
    {
      "environment": {{ .root.Values.global.environment | quote }},
      "customerApiBaseUrl": {{ .workload.runtimeConfig.customerApiBaseUrl | quote }},
      "accountApiBaseUrl": {{ .workload.runtimeConfig.accountApiBaseUrl | quote }},
      "transactionApiBaseUrl": {{ .workload.runtimeConfig.transactionApiBaseUrl | quote }}
    }
{{- end }}

{{- define "as-bank-library.service" -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ .name }}
  namespace: {{ .root.Values.global.namespace }}
  labels:
    {{- include "as-bank-library.labels" . | nindent 4 }}
spec:
  type: ClusterIP

  selector:
    {{- include "as-bank-library.selectorLabels" . | nindent 4 }}

  ports:
    - name: http
      port: 8080
      targetPort: http

    {{- if eq .workload.kind "java" }}
    - name: management
      port: 8081
      targetPort: management
    {{- end }}
{{- end }}

{{- define "as-bank-library.deployment" -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .name }}
  namespace: {{ .root.Values.global.namespace }}
  labels:
    {{- include "as-bank-library.labels" . | nindent 4 }}
spec:
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1

  selector:
    matchLabels:
      {{- include "as-bank-library.selectorLabels" . | nindent 6 }}

  template:
    metadata:
      labels:
        {{- include "as-bank-library.labels" . | nindent 8 }}

    spec:
      serviceAccountName: {{ .name }}
      automountServiceAccountToken: false
      terminationGracePeriodSeconds: 30

      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault

      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector:
            matchLabels:
              {{- include "as-bank-library.selectorLabels" . | nindent 14 }}

      containers:
        - name: {{ .name }}
          image: "{{ .root.Values.global.imageRegistry }}/{{ .workload.image.repository }}@{{ .workload.image.digest }}"
          imagePullPolicy: IfNotPresent

          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL

          ports:
            - name: http
              containerPort: 8080
              protocol: TCP

            {{- if eq .workload.kind "java" }}
            - name: management
              containerPort: 8081
              protocol: TCP
            {{- end }}

          {{- if eq .workload.kind "java" }}
          env:
            - name: SPRING_PROFILES_ACTIVE
              value: aws

            - name: SPRING_SECURITY_OAUTH2_RESOURCESERVER_JWT_ISSUER_URI
              value: {{ .root.Values.global.cognito.issuer | quote }}

            - name: ASBANK_SECURITY_EXPECTED_CLIENT_ID
              value: {{ .root.Values.global.cognito.clientId | quote }}

            - name: EXPECTED_CLIENT_ID
              value: {{ .root.Values.global.cognito.clientId | quote }}

            {{- if .workload.database.enabled }}
            - name: DB_HOST
              valueFrom:
                secretKeyRef:
                  name: {{ .name }}-database
                  key: DB_HOST

            - name: DB_PORT
              valueFrom:
                secretKeyRef:
                  name: {{ .name }}-database
                  key: DB_PORT

            - name: DB_NAME
              valueFrom:
                secretKeyRef:
                  name: {{ .name }}-database
                  key: DB_NAME

            - name: SPRING_DATASOURCE_USERNAME
              valueFrom:
                secretKeyRef:
                  name: {{ .name }}-database
                  key: DB_USERNAME

            - name: SPRING_DATASOURCE_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ .name }}-database
                  key: DB_PASSWORD

            - name: SPRING_DATASOURCE_URL
              value: "jdbc:postgresql://$(DB_HOST):$(DB_PORT)/$(DB_NAME)"
            {{- end }}
          {{- end }}

          startupProbe:
            httpGet:
              path: {{ .workload.probes.startupPath }}
              port: {{ .workload.probes.port }}
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 30

          readinessProbe:
            httpGet:
              path: {{ .workload.probes.readinessPath }}
              port: {{ .workload.probes.port }}
            periodSeconds: 5
            timeoutSeconds: 2
            failureThreshold: 3

          livenessProbe:
            httpGet:
              path: {{ .workload.probes.livenessPath }}
              port: {{ .workload.probes.port }}
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3

          lifecycle:
            preStop:
              exec:
                command:
                  - /bin/sh
                  - -c
                  - sleep 5

          resources:
            {{- toYaml .workload.resources | nindent 12 }}

          volumeMounts:
            - name: tmp
              mountPath: /tmp

            {{- if .workload.runtimeConfig.enabled }}
            - name: runtime-config
              mountPath: /usr/share/nginx/html/config.json
              subPath: config.json
              readOnly: true
            {{- end }}

      volumes:
        - name: tmp
          emptyDir:
            sizeLimit: 64Mi

        {{- if .workload.runtimeConfig.enabled }}
        - name: runtime-config
          configMap:
            name: {{ .name }}-runtime-config
        {{- end }}
{{- end }}

{{- define "as-bank-library.pdb" -}}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ .name }}
  namespace: {{ .root.Values.global.namespace }}
  labels:
    {{- include "as-bank-library.labels" . | nindent 4 }}
spec:
  maxUnavailable: 1

  selector:
    matchLabels:
      {{- include "as-bank-library.selectorLabels" . | nindent 6 }}
{{- end }}

{{- define "as-bank-library.hpa" -}}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ .name }}
  namespace: {{ .root.Values.global.namespace }}
  labels:
    {{- include "as-bank-library.labels" . | nindent 4 }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ .name }}

  minReplicas: {{ .workload.autoscaling.minReplicas }}
  maxReplicas: {{ .workload.autoscaling.maxReplicas }}

  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ .workload.autoscaling.cpuUtilization }}
{{- end }}

{{- define "as-bank-library.networkPolicy" -}}
{{- $hasIngress := gt (len .workload.network.ingressFrom) 0 -}}
{{- $hasServiceEgress := gt (len .workload.network.egressTo) 0 -}}
{{- $hasEgress := or $hasServiceEgress .workload.database.enabled .workload.network.allowHttpsEgress -}}

apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ .name }}
  namespace: {{ .root.Values.global.namespace }}
  labels:
    {{- include "as-bank-library.labels" . | nindent 4 }}
spec:
  podSelector:
    matchLabels:
      {{- include "as-bank-library.selectorLabels" . | nindent 6 }}

  policyTypes:
    - Ingress
    - Egress

  {{- if $hasIngress }}
  ingress:
    - from:
        {{- range .workload.network.ingressFrom }}
        - podSelector:
            matchLabels:
              app: {{ . | quote }}
              environment: {{ $.root.Values.global.environment | quote }}
        {{- end }}

      ports:
        - protocol: TCP
          port: 8080
  {{- else }}
  ingress: []
  {{- end }}

  {{- if $hasEgress }}
  egress:
    {{- range .workload.network.egressTo }}
    - to:
        - podSelector:
            matchLabels:
              app: {{ . | quote }}
              environment: {{ $.root.Values.global.environment | quote }}

      ports:
        - protocol: TCP
          port: 8080
    {{- end }}

    {{- if .workload.database.enabled }}
    - to:
        - ipBlock:
            cidr: {{ .root.Values.global.network.vpcCidr }}

      ports:
        - protocol: TCP
          port: 5432
    {{- end }}

    {{- if .workload.network.allowHttpsEgress }}
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0

      ports:
        - protocol: TCP
          port: 443
    {{- end }}
  {{- else }}
  egress: []
  {{- end }}
{{- end }}