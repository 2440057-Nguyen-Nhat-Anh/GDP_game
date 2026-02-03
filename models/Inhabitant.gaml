/**
* Name: Inhabitant
* Based on the internal empty template. 
* Author: anhnh
* Tags: 
*/


model Inhabitant

species default skills: [moving] {
    point target;
    rgb color <- rnd_color(255);
    
    // Chỉ khai báo cái vỏ aspect
    aspect default {
        draw circle(5) color: color;
    }
}