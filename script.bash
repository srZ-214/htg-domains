#!/bin/bash

RESULT_DIR="$PWD/results"
MEMORY_LIMIT="8G"
TIME_LIMIT=900
mkdir -p "$RESULT_DIR"

CSV="$RESULT_DIR/all_results.csv"
if [ ! -f "$CSV" ]; then
    # Initialize the CSV file with headers
    echo "domain,problem,our_transformation_time,our_fd_time,our_total_time,our_h_value,our_status,our_fd_ground_time,our_search_time,our_planning_time,baseline_total_time,baseline_h_value,baseline_status,baseline_fd_ground_time,baseline_search_time,baseline_planning_time" > "$CSV"
fi

timestamp(){
    python3 -c 'import time; print(time.time())'
}

timediff(){
    python3 -c "print(round($2 - $1, 3))"
}

extract_h_value(){
    local line=$(grep "Initial heuristic value" "$1" 2>/dev/null)
    if [ -z "$line" ]; then
        echo "N/A"
    elif echo "$line" | grep -q "infinity"; then
        echo "INF"
    else
        echo "$line" | grep -oE '[0-9]+' | tail -1
    fi
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

extract_fd_ground_time(){
    local log_file=$1
    # Find the first occurrence of "Done!" and extract the numeric value before "wall-clock"
    local time_val=$(grep "Done!" "$log_file" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+s wall-clock' | grep -oE '[0-9]+\.[0-9]+')
    if [ -z "$time_val" ]; then
        echo "N/A"
    else
        echo "$time_val"
    fi
}

run_cmd(){
for file in "$current_dir"/* ; do
    if [ -d "$file" ]; then
        continue
    fi
    if [ "$file" != "$current_dir/domain.pddl" ]; then
        # Create output directory
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

        # ---- OUR METHOD Step 1: Powerlifted Transformation ----
        echo ">>> [OUR] Step 1: Powerlifted Transformation"
        start1=$(timestamp)
        ../powerlifted/powerlifted.py -d "$current_dir/domain.pddl" -i "$file" \
            -s gbfs -e rdm -g yannakakis \
            --only-effects-novelty-check --unit-cost --keep-translator-file \
            2>&1 | tee "$out_dir/our_powerlifted.log"
        our_exit1=${PIPESTATUS[0]}
        end1=$(timestamp)
        our_t1=$(timediff $start1 $end1)

        # ---- OUR METHOD Step 2: FD on transformed PDDL ----
        if [ "$our_exit1" -ne 0 ]; then
            echo ">>> [OUR] Powerlifted FAILED (exit: $our_exit1)"
            our_t2="0"; our_total="$our_t1"; our_h="N/A"; our_status="TRANSFORMATION_FAIL"
            our_fd_ground_time="N/A"; our_search_time="N/A"; our_planning_time="N/A"
        else
            echo ">>> [OUR] Step 2: Fast Downward on transformed PDDL"
            start2=$(timestamp)
            ../downward/fast-downward.py \
                --overall-time-limit $TIME_LIMIT \
                --overall-memory-limit "$MEMORY_LIMIT" \
                dm.pddl pblm.pddl --search "astar(lmcut())" \
                2>&1 | tee "$out_dir/our_fd.log"
            our_exit2=${PIPESTATUS[0]}
            end2=$(timestamp)
            our_t2=$(timediff $start2 $end2)
            our_total=$(timediff $start1 $end2)
            our_h=$(extract_h_value "$out_dir/our_fd.log")
            our_status=$(extract_status "$out_dir/our_fd.log" "$our_exit2")

            # Dynamically calculate Planner time and Search time
            our_planning_time=$our_t2
            our_fd_ground_time=$(extract_fd_ground_time "$out_dir/our_fd.log")
            if [ "$our_fd_ground_time" != "N/A" ]; then
                # Search Time = Total Planner Time - FD Grounding Time
                our_search_time=$(python3 -c "print(max(0, round($our_planning_time - $our_fd_ground_time, 3)))")
            else
                our_search_time="N/A"
            fi

            [ -z "$our_h" ] && our_h="N/A"
        fi

        echo ">>> [OUR] Transformation: ${our_t1}s | FD: ${our_t2}s | Total: ${our_total}s | h=${our_h} | ${our_status}"

        # ---- BASELINE: FD directly on original PDDL ----
        echo ">>> [BASELINE] Fast Downward on original PDDL"
        start_b=$(timestamp)
        ../downward/fast-downward.py \
            --overall-time-limit $TIME_LIMIT \
            --overall-memory-limit "$MEMORY_LIMIT" \
            "$current_dir/domain.pddl" "$file" --search "astar(lmcut())" \
            2>&1 | tee "$out_dir/baseline_fd.log"
        baseline_exit=${PIPESTATUS[0]}
        end_b=$(timestamp)
        baseline_total=$(timediff $start_b $end_b)
        baseline_h=$(extract_h_value "$out_dir/baseline_fd.log")
        baseline_status=$(extract_status "$out_dir/baseline_fd.log" "$baseline_exit")

        # Dynamically calculate Planner time and Search time for BASELINE
        baseline_planning_time=$baseline_total
        baseline_fd_ground_time=$(extract_fd_ground_time "$out_dir/baseline_fd.log")
        if [ "$baseline_fd_ground_time" != "N/A" ]; then
            baseline_search_time=$(python3 -c "print(max(0, round($baseline_planning_time - $baseline_fd_ground_time, 3)))")
        else
            baseline_search_time="N/A"
        fi

        [ -z "$baseline_h" ] && baseline_h="N/A"

        echo ">>> [BASELINE] Total: ${baseline_total}s | h=${baseline_h} | ${baseline_status}"

        # ---- Save results ----
        cat > "$out_dir/summary.txt" <<EOF
Problem:
  $file
Date:       $(date '+%Y-%m-%d %H:%M:%S')
============================================
OUR METHOD
  Transformation (Powerlifted): ${our_t1}s
  FD Script execution time:     ${our_t2}s
  Total Shell Time:             ${our_total}s
  Initial h value:              ${our_h}
  FD Grounding Time:            ${our_fd_ground_time}s
  Calculated Search Time:       ${our_search_time}s
  Planning (FD Total) Time:     ${our_planning_time}s
  Status:                       ${our_status}
--------------------------------------------
BASELINE (FD on original PDDL)
  Total Shell Time:             ${baseline_total}s
  Initial h value:              ${baseline_h}
  FD Grounding Time:            ${baseline_fd_ground_time}s
  Calculated Search Time:       ${baseline_search_time}s
  Planning (FD Total) Time:     ${baseline_planning_time}s
  Status:                       ${baseline_status}
============================================
EOF

        # Write data to CSV
        echo "$rel_path,$filename,$our_t1,$our_t2,$our_total,$our_h,$our_status,$our_fd_ground_time,$our_search_time,$our_planning_time,$baseline_total,$baseline_h,$baseline_status,$baseline_fd_ground_time,$baseline_search_time,$baseline_planning_time" >> "$CSV"
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
