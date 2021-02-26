#!/bin/bash

# Copyright 2021 PingCAP, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# See the License for the specific language governing permissions and
# limitations under the License.

# This script patches the chart templates of tidb-operator to use
# in E2E tests.

set -e

echo "hack/e2e-patch-codecov.sh: PWD $PWD"

CONTROLLER_MANAGER_DEPLOYMENT=charts/tidb-operator/templates/controller-manager-deployment.yaml
SCHEDULER_DEPLOYMENT=charts/tidb-operator/templates/scheduler-deployment.yaml
DISCOVERY_DEPLOYMENT=charts/tidb-cluster/templates/discovery-deployment.yaml
ADMISSION_WEBHOOK_DEPLOYMENT=charts/tidb-operator/templates/admission/admission-webhook-deployment.yaml

DISCOVERY_MANAGER=pkg/manager/member/tidb_discovery_manager.go
RESTORE_MANAGER=pkg/backup/restore/restore_manager.go
BACKUP_MANAGER=pkg/backup/backup/backup_manager.go
BACKUP_CLEANER=pkg/backup/backup/backup_cleaner.go

echo "replace the entrypoint to generate and upload the coverage profile"
sed -i 's/\/usr\/local\/bin\/tidb-controller-manager/\/e2e-entrypoint.sh\n          - \/usr\/local\/bin\/tidb-controller-manager\n          - -test.coverprofile=\/coverage\/tidb-controller-manager.cov\n          - E2E/g' \
    $CONTROLLER_MANAGER_DEPLOYMENT
sed -i 's/\/usr\/local\/bin\/tidb-scheduler/\/e2e-entrypoint.sh\n          - \/usr\/local\/bin\/tidb-scheduler\n          - -test.coverprofile=\/coverage\/tidb-scheduler.cov\n          - E2E/g' \
    $SCHEDULER_DEPLOYMENT
sed -i 's/\/usr\/local\/bin\/tidb-discovery/\/e2e-entrypoint.sh\n          - \/usr\/local\/bin\/tidb-discovery\n          - -test.coverprofile=\/coverage\/tidb-discovery.cov\n          - E2E/g' \
    $DISCOVERY_DEPLOYMENT
sed -i 's/\/usr\/local\/bin\/tidb-admission-webhook/\/e2e-entrypoint.sh\n            - \/usr\/local\/bin\/tidb-admission-webhook\n            - -test.coverprofile=\/coverage\/tidb-admission-webhook.cov\n            - E2E/g' \
    $ADMISSION_WEBHOOK_DEPLOYMENT

# -v is duplicated for operator and go test
sed -i '/\-v=/d' $CONTROLLER_MANAGER_DEPLOYMENT
sed -i '/\-v=/d' $SCHEDULER_DEPLOYMENT
sed -i '/\-v=/d' $ADMISSION_WEBHOOK_DEPLOYMENT

# populate needed environment variables and local-path volumes
echo "hack/e2e-patch-codecov.sh: setting environment variables and volumes in charts"
cat << EOF >> $CONTROLLER_MANAGER_DEPLOYMENT
          - name: COMPONENT
            value: "controller-manager"
        volumeMounts:
          - mountPath: /coverage
            name: coverage
      volumes:
        - name: coverage
          hostPath:
            path: /mnt/disks/coverage
            type: Directory
EOF

# for SCHEDULER_DEPLOYMENT, no `env:` added with default values.
line=$(grep -n 'name: kube-scheduler' $SCHEDULER_DEPLOYMENT | cut -d ":" -f 1)
head -n $(($line-1)) $SCHEDULER_DEPLOYMENT > /tmp/scheduler-deployment.yaml
cat >> /tmp/scheduler-deployment.yaml <<EOF
        env:
        - name: COMPONENT
          value: "scheduler"
        volumeMounts:
          - mountPath: /coverage
            name: coverage
EOF
tail -n +$line $SCHEDULER_DEPLOYMENT >> /tmp/scheduler-deployment.yaml
cat << EOF >> /tmp/scheduler-deployment.yaml
      volumes:
        - name: coverage
          hostPath:
            path: /mnt/disks/coverage
            type: Directory
EOF
mv -f /tmp/scheduler-deployment.yaml $SCHEDULER_DEPLOYMENT

cat << EOF >> $DISCOVERY_DEPLOYMENT
          - name: COMPONENT
            value: "discovery"
        volumeMounts:
          - mountPath: /coverage
            name: coverage
      volumes:
        - name: coverage
          hostPath:
            path: /mnt/disks/coverage
            type: Directory
EOF

line=$(grep -n 'volumeMounts:' $ADMISSION_WEBHOOK_DEPLOYMENT | cut -d ":" -f 1)
head -n $(($line-1)) $ADMISSION_WEBHOOK_DEPLOYMENT > /tmp/admission-webhook-deployment.yaml
cat >> /tmp/admission-webhook-deployment.yaml <<EOF
          - name: COMPONENT
            value: "admission-webhook"
          volumeMounts:
            - mountPath: /coverage
              name: coverage
EOF
tail -n +$(($line+1)) $ADMISSION_WEBHOOK_DEPLOYMENT >> /tmp/admission-webhook-deployment.yaml
cat << EOF >> /tmp/admission-webhook-deployment.yaml
        - name: coverage
          hostPath:
            path: /mnt/disks/coverage
            type: Directory
EOF
mv -f /tmp/admission-webhook-deployment.yaml $ADMISSION_WEBHOOK_DEPLOYMENT

echo "hack/e2e-patch-codecov.sh: setting command, environment variables and volumes for golang code"

line=$(grep -n 'm.getTidbDiscoveryDeployment(tc)' $DISCOVERY_MANAGER | cut -d ":" -f 1)
head -n $(($line+3)) $DISCOVERY_MANAGER > /tmp/tidb_discovery_manager.go
cat >> /tmp/tidb_discovery_manager.go <<EOF
	d.Spec.Template.Spec.Containers[0].Command = []string{
		"/e2e-entrypoint.sh",
		"/usr/local/bin/tidb-discovery",
		"-test.coverprofile=/coverage/tidb-discovery.cov",
		"E2E",
	}
	d.Spec.Template.Spec.Containers[0].Env = append(d.Spec.Template.Spec.Containers[0].Env, corev1.EnvVar{
		Name:  "COMPONENT",
		Value: "discovery",
	})
	volType := corev1.HostPathDirectory
	d.Spec.Template.Spec.Volumes = append(d.Spec.Template.Spec.Volumes, corev1.Volume{
		Name: "coverage",
		VolumeSource: corev1.VolumeSource{
			HostPath: &corev1.HostPathVolumeSource{
				Path: "/mnt/disks/coverage",
				Type: &volType,
			},
		},
	})
	d.Spec.Template.Spec.Containers[0].VolumeMounts = append(d.Spec.Template.Spec.Containers[0].VolumeMounts, corev1.VolumeMount{
		Name:      "coverage",
		MountPath: "/coverage",
	})
EOF
tail -n +$(($line+4)) $DISCOVERY_MANAGER >> /tmp/tidb_discovery_manager.go
mv -f /tmp/tidb_discovery_manager.go $DISCOVERY_MANAGER

IFS= read -r -d '' PATCH_BR_JOB << EOF || true
	job.Spec.Template.Spec.Containers[0].Env = append(job.Spec.Template.Spec.Containers[0].Env, corev1.EnvVar{
		Name:  "COMPONENT",
		Value: "backup-manager",
	})
	volType := corev1.HostPathDirectory
	job.Spec.Template.Spec.Volumes = append(job.Spec.Template.Spec.Volumes, corev1.Volume{
		Name: "coverage",
		VolumeSource: corev1.VolumeSource{
			HostPath: &corev1.HostPathVolumeSource{
				Path: "/mnt/disks/coverage",
				Type: &volType,
			},
		},
	})
	job.Spec.Template.Spec.Containers[0].VolumeMounts = append(job.Spec.Template.Spec.Containers[0].VolumeMounts, corev1.VolumeMount{
		Name:      "coverage",
		MountPath: "/coverage",
	})
EOF

line=$(grep -n 'rm.deps.JobControl.CreateJob(restore, job)' $RESTORE_MANAGER | cut -d ":" -f 1)
head -n $(($line-1)) $RESTORE_MANAGER > /tmp/restore_manager.go
echo "$PATCH_BR_JOB" >> /tmp/restore_manager.go
tail -n +$line $RESTORE_MANAGER >> /tmp/restore_manager.go
mv -f /tmp/restore_manager.go $RESTORE_MANAGER

line=$(grep -n 'bm.deps.JobControl.CreateJob(backup, job)' $BACKUP_MANAGER | cut -d ":" -f 1)
head -n $(($line-1)) $BACKUP_MANAGER > /tmp/backup_manager.go
echo "$PATCH_BR_JOB"`` >> /tmp/backup_manager.go
tail -n +$line $BACKUP_MANAGER >> /tmp/backup_manager.go
mv -f /tmp/backup_manager.go $BACKUP_MANAGER

line=$(grep -n 'bc.deps.JobControl.CreateJob(backup, job)' $BACKUP_CLEANER | cut -d ":" -f 1)
head -n $(($line-1)) $BACKUP_CLEANER > /tmp/backup_cleaner.go
echo "$PATCH_BR_JOB"`` >> /tmp/backup_cleaner.go
tail -n +$line $BACKUP_CLEANER >> /tmp/backup_cleaner.go
mv -f /tmp/backup_cleaner.go $BACKUP_CLEANER
