///**
//* Name: NewModel
//* Based on the internal empty template. 
//* Author: anhnh
//* Tags: 
//*/
//
//
model NewModel
//import "Building.gaml"
//import "Road.gaml"
//import "Inhabitant.gaml"
//
///* Insert your model definition here */
//
//global {
//	file shapefile_buildings <- file("../includes/buildings.shp");
//	file shapefile_roads <- file("../includes/roads.shp");
//	
//	geometry shape <- envelope(shapefile_roads);
//	
//	graph road_network;
//	
//	road hover_road <- nil;
//	road selected_road <- nil;
//	
//	map<road, float> new_weight;
//	
////	reflex update_speed {
////		new_weight <- road as_map (each::each.shape.perimeter/each.speed_rate);	
////	}
//	
//	init {
//		create building from: shapefile_buildings with: (height: int(read("HEIGHT")));
//		
//		list<geometry> lines <- split_lines(shapefile_roads);
//		create road from: lines;
//		
//		write "Created roads: " + length(road);
//				
//		road_network <- as_edge_graph(road);
//
//		create inhabitant number: 1000 {
//			location <- any_location_in(one_of(building));
//		}
//	}
//}
//
////species building{
////	float height;
////	aspect default{
////		draw shape color: #gray border: #yellow;
////	} 
////}
//
////species road {
////	float capacity <- 1 + shape.perimeter / 30;
////	int nb_drivers <- 0 update: length(inhabitant at_distance 1);
////	float speed_rate <- 1.0 update: exp(-nb_drivers / capacity) min: 0.1;
////	
////	aspect default {
////		rgb road_color <- nil;
////		if (self = selected_road) {
////			road_color <- #purple;
////		} else if (self = hover_road) {
////			road_color <- #blue;
////		} else {
////			road_color <- #red;
////		}
////		
////		float thickness <- (1 + 3 * (1 - speed_rate));
////		draw (shape buffer (1 + 3 * (1 - speed_rate))) color: road_color;
////	}
////}
//
////species inhabitant skills: [moving] {
////	point target;
////	rgb color <- rnd_color(255);
////	float proba_leave <- 0.05;
////	float speed <- 5 #km/#h;
////	
////	reflex leave when: (target = nil) and (flip(proba_leave)) {
////		target <- any_location_in(one_of(building));
////	}
////	
////	reflex move when: (target != nil) {
////		do goto target: target on: road_network move_weights: new_weight;
////		if (location = target) {
////			target <- nil;
////		}
////	}
////	
////	aspect default {
////		draw circle(5) color: color;
////	}
////}
//
//
//experiment project type: gui {
//	output {
//		display map type: 3d axes: false background: #black{
//			species building aspect: default refresh: false;
//			species road aspect: default;			
//			species inhabitant aspect: default;
//			
//			event mouse_down {
//				point m_pos <- #user_location;
//				
//				ask world {
//					ask road {
//						is_selected <- false;
//					}
//					road r <- road closest_to m_pos;
//					
//					if (r != nil and (r distance_to m_pos < 15.0)) {
//						selected_road <- r;
//						r.is_selected <- true;
//						write "You just clicked: " + selected_road;
//					} else {
//						selected_road <- nil;
//					}
//				}
//			}
//			
//			event mouse_move {
//                point m_pos <- #user_location;
//                
//                ask world {
//                	ask road {
//                		is_hovered <- false;
//                	}
//                    road r <- road closest_to m_pos;
//                    if (r != nil and (r distance_to m_pos < 15.0)) {
//                        hover_road <- r;
//                        r.is_hovered <- true;
//                    } else {
//                        hover_road <- nil;
//                    }
//                }
//            }
//		}
//	}
//}