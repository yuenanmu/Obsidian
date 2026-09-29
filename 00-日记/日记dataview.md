```dataview
task
FROM "00-日记"
WHERE !completed
SORT file.day DESC
LIMIT 20
```