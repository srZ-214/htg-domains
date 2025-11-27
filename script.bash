#!/bin/bash

run_cmd(){
  for file in "$current_dir"/* ; do
    if [ "$file" != "$current_dir/domain.pddl" ];
      then echo "processing $file"
       ../powerlifted/powerlifted.py -d "$current_dir/domain.pddl" -i "$file" -s gbfs -e rdm -g yannakakis --only-effects-novelty-check --unit-cost --keep-translator-file
       ../downward/fast-downward.py domain.pddl task.pddl --search "astar(lmcut())"
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
  traverse_dir "$PWD"
}
main "$@"
