#!/bin/bash

set -e

cd "$(dirname "$0")/../lib"

pylint --recursive=y .
