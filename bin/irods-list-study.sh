#!/bin/bash

set -e

study_id=$1

(cat <<EOSQL
SELECT DISTINCT sample.name, iseq_product_metrics.tag_index,
   id_run, iseq_product_metrics.position, sample.supplier_name
FROM iseq_flowcell
   JOIN study USING(id_study_tmp)
   JOIN sample USING(id_sample_tmp)
   JOIN iseq_product_metrics USING(id_iseq_flowcell_tmp)
WHERE id_study_lims="${study_id}"
EOSQL
) | mysql --batch

