# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Zasada nadrzędna: zmiany infrastruktury tylko przez GitHub Actions

Każda zmiana infrastruktury (Terraform, GCE/GCS/VPC, klaster Kubernetes, release'y Helm, przełączanie slotów green/blue) wykonywana jest **wyłącznie przez workflow GitHub Actions**, nie z lokalnej maszyny ani z sesji Claude Code.

- Nie uruchamiaj lokalnie: `terraform apply`, `terraform destroy`, `terraform import`, `terraform state ...`, `scripts/deploy.sh`, `scripts/destroy.sh`, `scripts/green-blue-switch.sh deploy|switch|rollback`, `helm install|upgrade|uninstall`, `kubectl apply|delete|patch|scale`, `gcloud ... create|delete|update`, `gsutil cp|rm` do bucketów produkcyjnych.
- Zmiana infrastruktury = edycja plików w repo → commit na branchu → PR → uruchomienie workflow przez GitHub Actions (`gh workflow run`, `gh run watch` są dozwolone po potwierdzeniu z użytkownikiem).
- Zasada jest egzekwowana technicznie przez `permissions.deny` w `.claude/settings.json` (plik jest w repo: wyjątek `!.claude/settings.json` w `.gitignore`, sprawdź `git ls-files .claude/`). Zablokowane:
  - Terraform: `apply`, `destroy`, `import`, `taint`/`untaint`, `refresh`, `force-unlock`, `state mv|rm|push|replace-provider`, `workspace new|delete|select`;
  - `gcloud` (create, delete, update, patch, add-*/remove-*/set-*, start/stop/reset/resize, deploy, cp/mv/rm/rsync, `config set`, `auth`), `gsutil` (cp, mv, rm, rsync, mb, rb, acl, iam, …), `kubectl` (apply, create, delete, patch, replace, scale, edit, label, drain, exec, `rollout restart|undo`, …), `helm` (install, upgrade, uninstall, delete, rollback);
  - `scripts/deploy.sh`, `scripts/destroy.sh` oraz `green-blue-switch.sh deploy|switch|rollback`;
  - odczyt `.env` i `.env.local` (narzędzie `Read` oraz `cat`/`grep`/`source` itp.); `.env.example` pozostaje czytelny.
  - Reguły pokrywają też warianty: bez argumentów końcowych (`terraform apply`), z flagami globalnymi (`terraform -chdir=terraform apply`, `kubectl -n x delete`), wywołania przez `bash`/`sh`/`./`, `bash -c '...'`, `sudo`, `xargs` oraz polecenia łączone `&&`, `||`, `;`, `|`.
  - Dozwolone zostają polecenia odczytowe, m.in. `terraform plan|output|validate|fmt`, `gcloud ... list|describe`, `gsutil ls`, `kubectl get|logs|describe`, `helm list|lint|template` i `green-blue-switch.sh status`.
  - Ograniczenia: reguły to dopasowanie wzorców, nie sandbox — nie obejmują poleceń zdalnych (`ssh host "kubectl delete ..."`), skryptów wywołujących zablokowane polecenia w środku ani edycji plików. Nie omijaj blokady przeformułowaniem polecenia; jeśli zadanie jej wymaga, zatrzymaj się i zapytaj użytkownika.
  - Przy dodawaniu nowego narzędzia lub skryptu zmieniającego stan dopisz odpowiednie reguły `deny` w tym samym PR.
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

- **Terraform (`terraform/`)** tworzy VPC, firewall, dwa buckety GCS (`{project}-airflow-spark-dags`, `{project}-airflow-spark-bootstrap`) oraz VM-ki GCE: master (publiczny IP, `europe-west1-b`) i 1 worker (prywatne IP, `europe-central2`; limit projektu `CPUS_ALL_REGIONS` = 8 vCPU nie pozwala na więcej). Stan w zdalnym backendzie `gcs` (`backend "gcs" {}` w `main.tf`); bucket i prefix podawane przy init: `terraform init -backend-config="bucket=..." -backend-config="prefix=..."` (do lintu: `-backend=false`). Wcześniejszy lokalny `terraform.tfstate` musi zmigrować administrator przed pierwszym uruchomieniem CI. Klucz SSH: zmienna `ssh_public_key` (w CI `vars.SSH_PUBLIC_KEY`), fallback lokalny to plik z `ssh_pub_key_path`. Wdrożenie: `.github/workflows/deploy.yml` (`workflow_dispatch`; `run_apply` i `run_smoke_test` domyślnie wyłączone; projekt i hasła jako `TF_VAR_*`).
- **Bootstrap klastra jest w skryptach startowych VM**, nie w Terraformie: `scripts/master-init.sh` (kubeadm, Calico, local-path-provisioner, PostgreSQL, Airflow/JupyterHub/monitoring przez Helm, konta 16 analityków) i `scripts/worker-join.sh`. Master publikuje join-command do bucketu `bootstrap`, workery go stamtąd pobierają. Zmiana tych skryptów dotyczy tylko nowo tworzonych VM.
- **Airflow green/blue**: dwa release'y Helm (`helm/airflow/values-green.yaml`, `values-blue.yaml`) w namespace `airflow`; Service `airflow-active` (`k8s/airflow/service-active.yaml`, NodePort 30080) przełącza ruch selektorem `slot`. `scripts/green-blue-switch.sh` orkiestruje deploy/switch/rollback (włącza scheduler w nowym slocie, patchuje Service, wyłącza stary scheduler). Zmieniając konfigurację Airflow, aktualizuj oba pliki values spójnie.
- **DAG-i** żyją w GCS pod `dags/{analityk_username}/`; `dags/analityk_gcs_runner.py` to szablon: pobiera skrypt z GCS tokenem z metadata serwera GCE, uruchamia go (KubernetesExecutor) i sprząta. Izolacja analityków przez RBAC (`access_control`, rola per użytkownik).
- **Monitoring**: `helm/monitoring/*` (kube-prometheus, Loki, OTel Collector) + reguły alertów w `k8s/monitoring/airflow-alerts.yaml`.
- Porty NodePort (Airflow 30080, JupyterHub 30088, Grafana 30300, Prometheus 30090) muszą zgadzać się z regułami firewall w `terraform/network.tf`.

## Konwencje

- Commity zgodnie z [Conventional Commits](https://www.conventionalcommits.org/): `<typ>(<opcjonalny zakres>): <opis>`, np. `feat(terraform): add firewall rule for Grafana`, `fix(helm): correct scheduler replicas in values-blue`, `docs: update CLAUDE.md`. Typy: `feat`, `fix`, `docs`, `refactor`, `chore`, `ci`, `build`, `test`, `perf`, `style`, `revert`. Zmiana łamiąca kompatybilność: `!` po typie/zakresie lub stopka `BREAKING CHANGE:`. Opis w trybie rozkazującym, bez kropki na końcu, do ok. 72 znaków.
- README i komentarze w skryptach są po polsku; trzymaj ten język w dokumentacji i komunikatach skryptów.
- Sekrety (hasła Airflow/JupyterHub/Grafana) tylko w `.env` (w `.gitignore`, szablon `.env.example`); `*.json` jest ignorowane poza `helm/**/*.json` i `.claude/settings.json`.
