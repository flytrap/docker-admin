sudo cp kubectl-minio /usr/local/bin/
kubectl minio init -n minio

kubectl create namespace minio-tenant1
kubectl minio tenant create tenant1 -n minio-tenant1 --storage-class longhorn --servers 4 --volumes 4 --capacity 30Gi

kubectl -n minio-tenant-1 patch svc minio -p '{"spec": {"type": "NodePort"}}'
kubectl -n minio-tenant-1 patch svc minio-tenant-1-console -p '{"spec": {"type": "NodePort"}}'


