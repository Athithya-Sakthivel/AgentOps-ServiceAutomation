kind delete cluster --name local-cluster
kind create cluster --name local-cluster


make rollout-pg-cluster

make rollout-valkey

kind delete cluster --name local-cluster
kind create cluster --name local-cluster
make rollout-pg-cluster

kind delete cluster --name local-cluster
kind create cluster --name local-cluster
make rollout-pg-cluster
