#!/usr/bin/env bash

CODACY_RC="/.codacyrc"
FILES_DIR="/src"

CONFIG_FILE="/dc/config.json"
OUTPUT_FILE="/dc/output.json"
ANALYSIS_DIR="/dc/src"

# SUPPORT FUNCTIONS

function load_config_file {
  # Patterns are not configurable due to lack of global documentation
  codacy_patterns="";
}

function load_src_files {
  codacy_files=$(cd $FILES_DIR || exit; find . -type f -exec echo {} \; | cut -c3-)
}

function report_error {
  local file="$1"
  local output="$2"
  echo "{\"filename\":\"$file\",\"message\":\"found $output\",\"patternId\":\"foobar\",\"line\":1}"
}

function create_symlink {
  local file="$1"
  final_file="$FILES_DIR/$file"
  if [ -f "$final_file" ]; then
    link_file="$ANALYSIS_DIR/$file"
    parent_dir=$(dirname "$link_file")
    mkdir -p "$parent_dir"
    ln -s "$final_file" "$link_file"
  else
    echo "{\"filename\":\"$final_file\",\"message\":\"could not parse the file\"}"
  fi
}

# MAIN EXECUTION

if [ -f /.codacyrc ]; then
  #parse
  codacyrc_file=$(jq -erM '.' < $CODACY_RC)

  # error on invalid json
  if [ $? -ne 0 ]; then
    echo "Can't parse .codacyrc file"
    exit 1
  fi

  codacy_files=$(jq -cer '.files | .[]' <<< "$codacyrc_file")
  codacy_patterns=$(jq -cer '.tools | .[] | select(.name=="DeepCode") | .patterns | .[].patternId' <<< "$codacyrc_file")

  # When no patterns supplied
  if [ "$codacy_patterns" == "" ]; then
    load_config_file
  fi

  # When no files given, run with all files in /src
  if [ "$codacy_files" == "" ]; then
    load_src_files
  fi
else
  load_config_file
  load_src_files
fi

# Create symlinks for requested files into the analysis dir
# Directly passing the path of the files as arguments for the analysis would be
# more efficient, but bash has a limitation on the total length of arguments a
# command can have, and batching the paths would result in hundreds of parallel
# CLI executions which defies the purpose of having a CLI already managing it.
rm -rf "$ANALYSIS_DIR"
mkdir -p "$ANALYSIS_DIR"
while read -r file; do
  create_symlink "$file"
done <<< "$codacy_files"

# Spawn a child process for the analysis
(deepcode -c "$CONFIG_FILE" analyze -l -s -p "$ANALYSIS_DIR" 2>/dev/null >"$OUTPUT_FILE")&
analysis_pid=$!

# in the background, sleep for 10 mins (600 secs) then kill the analysis process.
# Athough the requested maximum timeout is 15 minutes, it's better to be stricter
# since we also require time to prepare the analysis dir and to parse the output.
(sleep 600 && kill -9 $analysis_pid)&
waiter_pid=$!

# wait on our worker process and return the exitcode
wait $analysis_pid 2>/dev/null
exitcode=$?

# kill the waiter subshell, if it still runs
kill -9 $waiter_pid 2>/dev/null
# 0 if we killed the waiter, cause that means the process finished before the waiter
finished_gracefully=$?
# avoid child termination message in the output
wait $waiter_pid 2>/dev/null


# TEST EXIT CODES AND OUTPUT FILE

if [ $finished_gracefully -ne 0 ]; then
  echo "Analysis timed out"
  exit 2
fi

if [ $exitcode -gt 1 ] || [ ! -s "$OUTPUT_FILE" ]; then
  echo "Analysis failed"
  exit 1
fi

if [ $exitcode -eq 0 ]; then
  # Analysis succeeded, but there is nothing to report
  exit 0
fi


# FORMAT OUTPUT

declare -A RULEMAP

output=$(cat $OUTPUT_FILE)

suggestion_indexes=$(jq -cer '.results.suggestions | keys_unsorted[]' <<< "$output")
file_indexes=$(jq -cer '.results.files | keys_unsorted[]' <<< "$output")

severity_map=( [1]="Info" [2]="Warning" [3]="Error" )
while read -r idx; do
  suggestion=$(jq -ce ".results.suggestions[\"$idx\"]" <<< "$output")
  message=$(jq -ce '.message' <<< "$suggestion")
  pattern_id=$(jq -ce '.id' <<< "$suggestion")
  severity=$(jq -cer '.severity' <<< "$suggestion")
  level=${severity_map[$severity]}
  if [ -z "$level" ]; then
    level="Info"
  fi
  RULEMAP["$idx"]="\"patternId\":$pattern_id,\"message\":$message,\"level\":\"$level\",\"category\": \"ErrorProne\""
done <<< "$suggestion_indexes"

# error on json parsing or associative array creation
if [ $? -ne 0 ]; then
  echo "Can't parse analysis output"
  exit 1
fi

escaped_dir=$(echo $ANALYSIS_DIR | sed 's/\//\\\//g')
while read -r file_path; do
  filename=$(echo $file_path | sed "s/^$escaped_dir\///")
  s_indexes=$(jq -cer ".results.files[\"$file_path\"] | keys_unsorted[]" <<< "$output")
  while read -r sidx; do
    s_lines=$(jq -cer ".results.files[\"$file_path\"][\"$sidx\"] | .[].rows[0]" <<< "$output")
    while read -r line; do
      echo "{\"filename\":\"$filename\",\"line\":$line,${RULEMAP[$sidx]}}"
    done <<< "$s_lines"
  done <<< "$s_indexes"
done <<< "$file_indexes"

exit 0
