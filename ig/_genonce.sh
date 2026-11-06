#!/bin/bash
set -e
export JAVA_TOOL_OPTIONS="$JAVA_TOOL_OPTIONS -Dfile.encoding=UTF-8"
publisher_jar=publisher.jar
input_cache_path=./input-cache

echo "Running SUSHI..."
npx fsh-sushi .

if [ -f "$input_cache_path/$publisher_jar" ]; then
    java -jar "$input_cache_path/$publisher_jar" -ig . "$@"
elif [ -f "$publisher_jar" ]; then
    java -jar "$publisher_jar" -ig . "$@"
else
    echo "Publisher JAR not found. Run ./_updatePublisher.sh first, or run 'npx fsh-sushi .' / 'raco fsh input/fsh/' for FSH compilation."
fi
