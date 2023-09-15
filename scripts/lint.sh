#!/bin/bash

set -e

cd "$(dirname "$0")/.."

pylint --recursive=y .
