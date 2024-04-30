# just is a command runner, Justfile is very similar to Makefile, but simpler.

############################################################################
#
#  
#
############################################################################

default:
    just --list

# Update the flake
test:
    bundle exec jekyll serve --host 0.0.0.0 --port 4000

post name:
    bundle exec jekyll post "{{name}}"

draft name:
    bundle exec jekyll draft "{{name}}"

publish name:
    bundle exec jekyll publish "_drafts/{{name}}.md"