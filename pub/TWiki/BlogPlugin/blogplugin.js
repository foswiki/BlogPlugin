// add/remove a tag in an input field
// theID: name of the input field
// theTag: the tag
function toggleTag(fieldName, theTag) {
  var inputField = document.getElementsByName(fieldName);
  if (!inputField) {
    /*window.alert("Warning: field '"+fieldName+"' not found in form");*/
    return;
  }
  inputField = inputField[0];
  var fieldValue = inputField.value;
  fieldValue = fieldValue.replace(/,/g,"");
  var tags = fieldValue.split(" ");
  var newTags = new Array();
  var found = false;
  for (var i = 0; i < tags.length; i++)  {
    var tag = tags[i];
    var tagElem = document.getElementById(tag);
    if (tagElem) {
      tagElem.className = '';
    }
    if (tag == theTag) {
      found = true;
    } else {
      newTags.push(tag);
    }
  }
  if (!found) {
    newTags.push(theTag)
  }
  newTags.sort();
  inputField.value = newTags.join(" ");

  for (var i = 0; i < newTags.length; i++) {
    var tagElem = document.getElementById(newTags[i]);
    if (tagElem) {
      tagElem.className = 'current';
    }
  }
}
var prevHiliteElements = new Array();
function hiliteTagCloud (elems, name) {
  for (var i = 0; i < prevHiliteElements.length; i++) {
    var elem = document.getElementById(prevHiliteElements[i]);
    if (elem) {
      elem.className = '';
    }
  }
  elems = elems.split(/[, ]+/);
  prevHiliteElements = elems;
  for (var i = 0; i < elems.length; i++) {
    var elem = document.getElementById(elems[i]);
    if (elem) {
      elem.className = name;
    }
  }
}
