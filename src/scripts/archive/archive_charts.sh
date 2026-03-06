# sigoz chart v0.113.0 → local dir
helm repo add signoz https://charts.signoz.io
helm repo update
helm pull signoz/signoz --version 0.113.0 --untar --untardir src/helm

# cloudnative-pg operator chart (pick the chart version that matches operator 1.28.1 / chart 0.27.x)
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm repo update
helm pull cnpg/cloudnative-pg --version 0.27.1 --untar --untardir src/helm