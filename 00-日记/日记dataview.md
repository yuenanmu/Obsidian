```dataview
TASK
FROM "00-日记"
WHERE !completed AND !contains(section.subpath, "明天计划")
SORT file.day DESC
LIMIT 20
```
