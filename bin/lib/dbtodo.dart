class DBTodo {
int id = 0;
String title = '';
String description = '';

DBTodo({required this.id, required this.title, required this.description});
factory DBTodo.fromJson(Map<String, dynamic> json) => DBTodo(
  id:json['id'] ?? ' ',
  title: json['title'] ?? '', 
  description:   json ['description'] ?? '',
);
Map<String,dynamic> toMap() => {
  'id':id,
  'title': title,
  'description': description,
};
 }
 