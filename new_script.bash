#!/bin/bash


RESULT_DIR="$PWD/results"
TIME_LIMIT=1800
mkdir -p "$RESULT_DIR"

CSV="$RESULT_DIR/all_results.csv"
if [ ! -f "$CSV" ]; then
    echo "domain,problem,our_grounding_time,our_fd_time,our_total_time,our_h_value,our_status,baseline_total_time,baseline_h_value,baseline_status" > "$CSV"
fi

timestamp(){
    python3 -c 'import time; print(time.time())'
}

timediff(){
    python3 -c "print(round($2 - $1, 3))"
}

extract_h_value(){
    grep "Initial heuristic value" "$1" 2>/dev/null | grep -oE '[0-9]+' | tail -1
}

extract_status(){
    local log=$1 exit_code=$2
    case $exit_code in
        0|1|2|3) echo "SUCCESS" ;;
        10|11|12) echo "UNSOLVABLE" ;;
        20|21|22|24|137) echo "OOM" ;;
        23) echo "TIMEOUT" ;;
        *) echo "ERROR" ;;
    esac
}

run_cmd(){
for file in "$current_dir"/* ; do
    if [ -d "$file" ]; then
        continue
    fi
    if [ "$file" != "$current_dir/domain.pddl" ]; then
        # creat outputfile
        filename=$(basename "$file" .pddl)
        rel_path="${current_dir#$PWD/}"
        out_dir="$RESULT_DIR/$rel_path/$filename"
        mkdir -p "$out_dir"

        if [ -f "$out_dir/summary.txt" ]; then
            echo "SKIP (already done): $file"
            continue
        fi
        
        echo "========================================================"
        echo "processing $file"
        echo "========================================================"

        # ---- OUR METHOD Step 1: Powerlifted ----
        echo ">>> [OUR] Step 1: Powerlifted"
        start1=$(timestamp)
        ../powerlifted/powerlifted.py -d "$current_dir/domain.pddl" -i "$file" \
            -s gbfs -e rdm -g yannakakis \
            --only-effects-novelty-check --unit-cost --keep-translator-file \
            2>&1 | tee "$out_dir/our_powerlifted.log"
        our_exit1=${PIPESTATUS[0]}
        end1=$(timestamp)
        our_t1=$(timediff $start1 $end1)

        # ---- OUR METHOD Step 2: FD on grounded PDDL ----
        if [ "$our_exit1" -ne 0 ]; then
            echo ">>> [OUR] Powerlifted FAILED (exit: $our_exit1)"
            our_t2="0"; our_total="$our_t1"; our_h="N/A"; our_status="GROUNDING_FAIL"
        else
            echo ">>> [OUR] Step 2: Fast Downward on grounded PDDL"
            start2=$(timestamp)
            ../downward/fast-downward.py \
                --overall-time-limit $TIME_LIMIT --overall-memory-limit 8G \
                dm.pddl pblm.pddl --search "astar(lmcut())" \
                2>&1 | tee "$out_dir/our_fd.log"
            our_exit2=${PIPESTATUS[0]}
            end2=$(timestamp)
            our_t2=$(timediff $start2 $end2)
            our_total=$(timediff $start1 $end2)
            our_h=$(extract_h_value "$out_dir/our_fd.log")
            our_status=$(extract_status "$out_dir/our_fd.log" "$our_exit2")
            [ -z "$our_h" ] && our_h="N/A"
        fi

        echo ">>> [OUR] Grounding: ${our_t1}s | FD: ${our_t2}s | Total: ${our_total}s | h=${our_h} | ${our_status}"

        # ---- BASELINE: FD directly on original PDDL ----
        echo ">>> [BASELINE] Fast Downward on original PDDL"
        start_b=$(timestamp)
        ../downward/fast-downward.py \
            --overall-time-limit $TIME_LIMIT --overall-memory-limit 8G \
            "$current_dir/domain.pddl" "$file" --search "astar(lmcut())" \
            2>&1 | tee "$out_dir/baseline_fd.log"
        baseline_exit=${PIPESTATUS[0]}
        end_b=$(timestamp)
        baseline_total=$(timediff $start_b $end_b)
        baseline_h=$(extract_h_value "$out_dir/baseline_fd.log")
        baseline_status=$(extract_status "$out_dir/baseline_fd.log" "$baseline_exit")
        [ -z "$baseline_h" ] && baseline_h="N/A"

        echo ">>> [BASELINE] Total: ${baseline_total}s | h=${baseline_h} | ${baseline_status}"

        # ---- Save results ----
        cat > "$out_dir/summary.txt" <<EOF
Problem:    $file
Date:       $(date '+%Y-%m-%d %H:%M:%S')
============================================
OUR METHOD
  Grounding (Powerlifted): ${our_t1}s
  FD on grounded PDDL:     ${our_t2}s
  Total:                    ${our_total}s
  Initial h value:          ${our_h}
  Status:                   ${our_status}
--------------------------------------------
BASELINE (FD on original PDDL)
  Total:                    ${baseline_total}s
  Initial h value:          ${baseline_h}
  Status:                   ${baseline_status}
============================================
EOF

        echo "$rel_path,$filename,$our_t1,$our_t2,$our_total,$our_h,$our_status,$baseline_total,$baseline_h,$baseline_status" >> "$CSV"
        echo ""
    fi
done
}

traverse_dir(){
 local current_dir=$1
 echo "current dir :$current_dir"


  if [ -f "$current_dir/domain.pddl" ]; then
    echo "find domain file, running test under $current_dir"

    run_cmd
  fi

  for item in "$current_dir"/*; do
    if [ -d "$item" ]; then
      traverse_dir "$item"
    fi
  done


 }

main(){
    echo "Experiment started: $(date)"
    echo "Results: $RESULT_DIR"
    echo ""
    traverse_dir "$PWD"
    echo ""
    echo "Experiment finished: $(date)"
    echo "CSV: $CSV"
}

main "$@"
