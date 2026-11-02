# Registry pull secret: placeholder

No Secret, ciphertext or credential is stored here. This document is not a
manifest and is not a Kustomization resource. The Deployment references
`forgejo-registry`. Before activation, seal a read-only package credential as a
strictly name- and namespace-bound SealedSecret named `forgejo-registry` of type
`kubernetes.io/dockerconfigjson`, separately for `website-dev` and
`website-prod`. Use the controller's public certificate and stdin-only
plaintext; never put plaintext in files, argv or logs.

The onboarding change adds each sealed manifest to its overlay's
`kustomization.yaml` together with the consuming Deployment. Never add a
reference to a missing file, reuse ciphertext between namespaces, or deploy
`UNRELEASED`. Activation must prove a fresh pod pulls successfully.

In the private repository the two sealed manifests sit beside each overlay; this
public copy omits them (see [docs/secrets.md](../../../../../../docs/secrets.md)).
