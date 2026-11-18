# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Zasada nadrzędna: zmiany infrastruktury tylko przez GitHub Actions

Każda zmiana infrastruktury (Terraform, GCE/GCS/VPC, klaster Kubernetes, release'y Helm, przełączanie slotów green/blue) wykonywana jest **wyłącznie przez workflow GitHub Actions**, nie z lokalnej maszyny ani z sesji Claude Code.

- Nie uruchamiaj lokalnie: `terraform apply`, `terraform destroy`, `terraform import`, `terraform state ...`, `scripts/deploy.sh`, `scripts/destroy.sh`, `scripts/green-blue-switch.sh deploy|switch|rollback`, `helm install|upgrade|uninstall`, `kubectl apply|delete|patch|scale`, `gcloud ... create|delete|update`, `gsutil cp|rm` do bucketów produkcyjnych.
- Zmiana infrastruktury = edycja plików w repo → commit na branchu → PR → uruchomienie workflow przez GitHub Actions (`gh workflow run`, `gh run watch` są dozwolone po potwierdzeniu z użytkownikiem).
- `.claude/settings.json` już blokuje `Bash(*deploy.sh*)`; ta zasada jest szersza i obowiązuje także tam, gdzie nie ma technicznej blokady.
- Stan na dziś: w repo **nie ma jeszcze** katalogu `.github/workflows/`. Jeśli zadanie wymaga wdrożenia, zaproponuj dodanie workflow zamiast wdrażać ręcznie.

## Polecenia tylko do odczytu (bezpieczne)

```bash
# Terraform (z katalogu terraform/)
terraform fmt -check -recursive      # sprawdzenie formatowania
terraform init -backend=false        # init bez dotykania stanu
terraform validate
terraform plan -var="project_id=$PROJECT_ID"   # tylko plan, bez apply
terraform output

# GCP
gcloud config list
gcloud compute instances list
gcloud compute instances describe <nazwa> --zone <strefa>
gcloud storage ls gs://<project>-airflow-spark-dags/dags/
gcloud logging read '<filtr>' --limit 50

# Kubernetes (przez SSH na master lub z kubeconfig)
kubectl get nodes -o wide
kubectl get pods -A
kubectl logs -n airflow -l component=scheduler --tail=100
kubectl logs -n jupyterhub -l component=hub --tail=100
kubectl get svc airflow-active -n airflow -o jsonpath='{.spec.selector.slot}'   # aktywny slot
./scripts/green-blue-switch.sh status

# Git / GitHub
git status; git diff; gh run list; gh pr view
```

## Lintowanie

W repo nie ma skonfigurowanego lintera ani CI — poniższe to polecenia do uruchamiania ręcznie (narzędzia trzeba mieć zainstalowane lokalnie):

```bash
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform init -backend=false && terraform -chdir=terraform validate
shellcheck scripts/*.sh
helm lint helm/<chart>                       # jeśli dostępny katalog chartu; values: helm template ... -f helm/airflow/values-green.yaml
ruff check dags notebooks stress_test.py     # Python
python -I -m py_compile dags/*.py            # szybki test składni DAGów
```

Brak testów jednostkowych w repo.

## Architektura (big picture)

- **Terraform (`terraform/`)** tworzy VPC, firewall, dwa buckety GCS (`{project}-airflow-spark-dags`, `{project}-airflow-spark-bootstrap`) oraz VM-ki GCE: master (publiczny IP, `europe-west1-b`) i 2 workery (prywatne IP, inne regiony). Stan lokalny (`terraform.tfstate`, w `.gitignore`) — brak zdalnego backendu, więc stan nie jest współdzielony; to kolejny powód, by apply szedł z jednego miejsca (GitHub Actions).
- **Bootstrap klastra jest w skryptach startowych VM**, nie w Terraformie: `scripts/master-init.sh` (kubeadm, Calico, local-path-provisioner, PostgreSQL, Airflow/JupyterHub/monitoring przez Helm, konta 16 analityków) i `scripts/worker-join.sh`. Master publikuje join-command do bucketu `bootstrap`, workery go stamtąd pobierają. Zmiana tych skryptów dotyczy tylko nowo tworzonych VM.
- **Airflow green/blue**: dwa release'y Helm (`helm/airflow/values-green.yaml`, `values-blue.yaml`) w namespace `airflow`; Service `airflow-active` (`k8s/airflow/service-active.yaml`, NodePort 30080) przełącza ruch selektorem `slot`. `scripts/green-blue-switch.sh` orkiestruje deploy/switch/rollback (włącza scheduler w nowym slocie, patchuje Service, wyłącza stary scheduler). Zmieniając konfigurację Airflow, aktualizuj oba pliki values spójnie.
- **DAG-i** żyją w GCS pod `dags/{analityk_username}/`; `dags/analityk_gcs_runner.py` to szablon: pobiera skrypt z GCS tokenem z metadata serwera GCE, uruchamia go (KubernetesExecutor) i sprząta. Izolacja analityków przez RBAC (`access_control`, rola per użytkownik).
- **Monitoring**: `helm/monitoring/*` (kube-prometheus, Loki, OTel Collector) + reguły alertów w `k8s/monitoring/airflow-alerts.yaml`.
- Porty NodePort (Airflow 30080, JupyterHub 30088, Grafana 30300, Prometheus 30090) muszą zgadzać się z regułami firewall w `terraform/network.tf`.

## Konwencje

- Commity zgodnie z [Conventional Commits](https://www.conventionalcommits.org/): `<typ>(<opcjonalny zakres>): <opis>`, np. `feat(terraform): add firewall rule for Grafana`, `fix(helm): correct scheduler replicas in values-blue`, `docs: update CLAUDE.md`. Typy: `feat`, `fix`, `docs`, `refactor`, `chore`, `ci`, `build`, `test`, `perf`, `style`, `revert`. Zmiana łamiąca kompatybilność: `!` po typie/zakresie lub stopka `BREAKING CHANGE:`. Opis w trybie rozkazującym, bez kropki na końcu, do ok. 72 znaków.
- README i komentarze w skryptach są po polsku; trzymaj ten język w dokumentacji i komunikatach skryptów.
- Sekrety (hasła Airflow/JupyterHub/Grafana) tylko w `.env` (w `.gitignore`, szablon `.env.example`); `*.json` jest ignorowane poza `helm/**/*.json` i `.claude/settings.json`.
