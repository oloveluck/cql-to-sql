#!/bin/bash
set -e
mkdir -p input-cache
echo "Downloading latest HL7 FHIR IG Publisher..."
curl -L https://github.com/HL7/fhir-ig-publisher/releases/latest/download/publisher.jar -o input-cache/publisher.jar
echo "Download complete."
