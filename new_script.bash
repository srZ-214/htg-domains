#!/bin/bash

RESULT_DIR="$PWD/results"
TIME_LIMIT=1800   # 30 minutes total budget for each method
mkdir -p "$RESULT_DIR"

# ---- Heuristic configurations ----
# Delete-relaxation heuristics (equivalent on our representation)
HEURISTICS=(
    "lmcut:astar(lmcut())"
    "hmax:astar(hmax())"
    "hadd:astar(hadd())"
    "ff:astar(ff())"
    "cea:astar(cea())"
    # Non-delete-relaxation (optional)
    # "mas:astar(merge_and_shrink())"
    # "cegar:astar(cegar())"
    # "blind:astar(blind())"
)

CSV="$RESULT_DIR/all_results.csv"
if [ ! -f "$CSV" ]; then
    echo "domain,problem,heuristic,our_grounding_time,our_fd_time,our_total_time,our_h_value,our_status,baseline_total_time,baseline_h_value,baseline_status" > "$CSV"
fi

timestamp(){
    python3 -c 'import time; print(time.time())'
}

timediff(){
    python3 -c "print(round($2 - $1, 3))"
}

# Returns integer seconds (floor), for --overall-time-limit
remaining_time_int(){
    python3 -c "
t = int($TIME_LIMIT - $1)
print(max(t, 0))
"
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
            filename=$(basename "$file" .pddl)
            rel_path="${current_dir#$PWD/}"
            out_dir="$RESULT_DIR/$rel_path/$filename"
            mkdir -p "$out_dir"

            echo "========================================================"
            echo "Processing: $file"
            echo "========================================================"

            # ---- OUR METHOD Step 1: Powerlifted (once per problem) ----
            our_grounding_done=0
            our_t1="0"
            our_exit1=1

            for hcfg in "${HEURISTICS[@]}"; do
                hname="${hcfg%%:*}"
                hsearch="${hcfg##*:}"

                h_out_dir="$out_dir/$hname"
                mkdir -p "$h_out_dir"

                if [ -f "$h_out_dir/summary.txt" ]; then
                    echo "SKIP (already done): $file / $hname"
                    continue
                fi

                echo "--------------------------------------------------------"
                echo "  Heuristic: $hname  ($hsearch)"
                echo "--------------------------------------------------------"

                # Run grounding only once per problem
                if [ "$our_grounding_done" -eq 0 ]; then
                    echo ">>> [OUR] Step 1: Powerlifted grounding"
                    start1=$(timestamp)
                    timeout $TIME_LIMIT \
                        ../powerlifted/powerlifted.py -d "$current_dir/domain.pddl" -i "$file" \
                            -s gbfs -e rdm -g yannakakis \
                            --only-effects-novelty-check --unit-cost --keep-translator-file \
                            2>&1 | tee "$out_dir/our_powerlifted.log"
                    our_exit1=${PIPESTATUS[0]}
                    end1=$(timestamp)
                    our_t1=$(timediff $start1 $end1)
                    our_grounding_done=1

                    # Check if grounding itself timed out (exit 124 from timeout cmd)
                    if [ "$our_exit1" -eq 124 ]; then
                        echo ">>> [OUR] Grounding TIMEOUT (${our_t1}s >= ${TIME_LIMIT}s)"
                        our_exit1=1  # mark as failed
                    else
                        echo ">>> [OUR] Grounding done: ${our_t1}s (exit: $our_exit1)"
                    fi
                fi

                # ---- OUR METHOD Step 2: FD with remaining time budget ----
                fd_time_limit=0
                if [ "$our_exit1" -ne 0 ]; then
                    echo ">>> [OUR] Powerlifted FAILED, skipping FD"
                    our_t2="0"; our_total="$our_t1"; our_h="N/A"; our_status="GROUNDING_FAIL"
                else
                    fd_time_limit=$(remaining_time_int $our_t1)

                    if [ "$fd_time_limit" -le 0 ]; then
                        echo ">>> [OUR] No time left for FD after grounding (${our_t1}s used)"
                        our_t2="0"; our_total="$our_t1"; our_h="N/A"; our_status="TIMEOUT"
                    else
                        echo ">>> [OUR] Step 2: FD with $hname (time limit: ${fd_time_limit}s)"
                        start2=$(timestamp)
                        ../downward/fast-downward.py \
                            --overall-time-limit "$fd_time_limit" \
                            dm.pddl pblm.pddl --search "$hsearch" \
                            2>&1 | tee "$h_out_dir/our_fd.log"
                        our_exit2=${PIPESTATUS[0]}
                        end2=$(timestamp)
                        our_t2=$(timediff $start2 $end2)
                        our_total=$(python3 -c "print(round($our_t1 + $our_t2, 3))")
                        our_h=$(extract_h_value "$h_out_dir/our_fd.log")
                        our_status=$(extract_status "$h_out_dir/our_fd.log" "$our_exit2")
                        [ -z "$our_h" ] && our_h="N/A"
                    fi
                fi

                echo ">>> [OUR/$hname] Grounding: ${our_t1}s | FD: ${our_t2}s | Total: ${our_total}s | h=${our_h} | ${our_status}"

                # ---- BASELINE: FD on original PDDL (full time budget) ----
                echo ">>> [BASELINE] FD with $hname on original PDDL (time limit: ${TIME_LIMIT}s)"
                start_b=$(timestamp)
                ../downward/fast-downward.py \
                    --overall-time-limit $TIME_LIMIT \
                    "$current_dir/domain.pddl" "$file" --search "$hsearch" \
                    2>&1 | tee "$h_out_dir/baseline_fd.log"
                baseline_exit=${PIPESTATUS[0]}
                end_b=$(timestamp)
                baseline_total=$(timediff $start_b $end_b)
                baseline_h=$(extract_h_value "$h_out_dir/baseline_fd.log")
                baseline_status=$(extract_status "$h_out_dir/baseline_fd.log" "$baseline_exit")
                [ -z "$baseline_h" ] && baseline_h="N/A"

                echo ">>> [BASELINE/$hname] Total: ${baseline_total}s | h=${baseline_h} | ${baseline_status}"

                # ---- Save results ----
                cat > "$h_out_dir/summary.txt" <<EOF
Problem:    $file
Heuristic:  $hname ($hsearch)
Date:       $(date '+%Y-%m-%d %H:%M:%S')
Time Limit: ${TIME_LIMIT}s total per method
============================================
OUR METHOD
  Grounding (Powerlifted): ${our_t1}s
  FD time limit:            ${fd_time_limit}s
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

                echo "$rel_path,$filename,$hname,$our_t1,$our_t2,$our_total,$our_h,$our_status,$baseline_total,$baseline_h,$baseline_status" >> "$CSV"
                echo ""
            done
        fi
    done
}

traverse_dir(){
    local current_dir=$1
    echo "current dir: $current_dir"

    if [ -f "$current_dir/domain.pddl" ]; then
        echo "Found domain file, running tests under $current_dir"
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
    echo "Time limit: ${TIME_LIMIT}s per method per problem"
    echo "Heuristics: ${HEURISTICS[*]}"
    echo ""
    traverse_dir "$PWD"
    echo ""
    echo "Experiment finished: $(date)"
    echo "CSV: $CSV"
}

main "$@"