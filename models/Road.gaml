/**
* Name: Road
* Based on the internal empty template. 
* Author: anhnh
* Tags: 
*/


model Road

species road {
    bool is_selected <- false;
    bool is_hovered <- false;
    float speed_rate <- 1.0;
    int nb_drivers <- 0;

    reflex update_traffic {
        list<agent> nearby_agents <- agents_at_distance(2.0);
        
        int counter <- 0;
        loop a over: nearby_agents {
//            if (a.species.name = "inhabitant") {
//                counter <- counter + 1;
//            }
        }
        nb_drivers <- counter;
        
        float capacity <- 1 + shape.perimeter / 30;
        
        float calculated_speed <- exp(-nb_drivers / capacity);
        speed_rate <- (calculated_speed < 0.1) ? 0.1 : calculated_speed;
    }

    aspect default {
        rgb road_color <- #red;
        if (is_selected) { road_color <- #purple; }
        else if (is_hovered) { road_color <- #blue; }
        
        draw shape + (1 + 3 * (1 - speed_rate)) color: road_color;
    }
}